require 'socketeer'
require 'fifo'
require 'logger'

Thread.abort_on_exception = true

$log = Logger.new STDOUT
$log.level = Logger::DEBUG

class FFMpegger

  include Messenger

  @@ffmpeg_command = File.absolute_path('bin/ffmpeg')

  def initialize
    @heartbeats = {}
    @previous_keys = []
  end

  def cycle
    msg = pop_message
    handle_data msg[:pipe_path], msg[:data] unless msg.nil?
    push_new_ffmpeg_data
    clean_heartbeats
    restart_ffmpeg if ffmpeg_needs_restart? && has_sources?
  end

  def handle_data pipe_path, data
    $log.debug "Handle Data: #{pipe_path} #{data.length}"
    heartbeat pipe_path
  end

  private

  def push_new_ffmpeg_data
    begin
      unless @ffmpeg_pipe.nil?
        data = ''
        loop do
          data << @ffmpeg_pipe.read_nonblock(4096)
        end
      end
    rescue IO::WaitReadable 
      # nothing left to read
    end
    return false if data.nil? || data.empty?
    $log.debug "FFMPEG Data: #{data.length}"
    push_message({:data=>data}) unless data.nil?
  end

  def restart_ffmpeg
    $log.info "FFMPEG Restart"
    stop_ffmpeg
    start_ffmpeg
  end

  def start_ffmpeg
    $log.info "FFMPEG Starting"
    cmd = ffmpeg_command
    $log.info "FFMPEG Command: #{cmd}"
    @ffmpeg_pipe = IO.popen(cmd, 'r')
    $log.info "FFMPEG PID: #{@ffmpeg_pipe.pid}"
  end

  def ffmpeg_command
    "#{@@ffmpeg_command} #{arg_string}"
  end

  def arg_string 
    ffmpeg_args.join(' ')
  end

  def ffmpeg_args
    args = []
    args << '-v verbose'
    @heartbeats.each do |fifo_path, last_heartbeat|
      args << "-i #{fifo_path}"
    end
    args << '-filter_complex'

    # output a square video for simplicity
    output_width = output_height = 1024
    number_of_inputs = @heartbeats.length
    cells_per_side = Math.sqrt(number_of_inputs).ceil # round up
    cell_size = output_width / cells_per_side
    $log.debug "OUTPUT WIDTH: #{output_width}"
    $log.debug "NUMBER OF INPUTS: #{number_of_inputs}"
    $log.debug "CELLS PER SIDE: #{cells_per_side}"
    $log.debug "CELL SIZE: #{cell_size}"

    _arg = '"'
    # create initial padding to create correct size area
    _arg << "[0:0]pad=#{output_width}:#{output_height}[a];"

    # scale our inputs
    stream_letter = 'a'
    @heartbeats.keys.each_with_index do |_, i|
      stream_letter = (98 + i).chr
      _arg << "[#{i}:0]scale=#{cell_size}:-1[#{stream_letter}];"
    end

    # line our inputs up
    last_new_stream_letter = 'a'
    @heartbeats.keys.each_with_index do |fifo_path, i|
      new_stream_letter = (last_new_stream_letter.ord + 1).chr
      input_stream_letter = (98 + i).chr
      row_i = i % cells_per_side
      col_i = i % (i * cells_per_side) rescue 0
      _arg << "[#{last_new_stream_letter}][#{input_stream_letter}]" + \
              "overlay=#{cell_size*row_i}:#{cell_size*col_i}[#{new_stream_letter}];"
      last_new_stream_letter = new_stream_letter
    end
    # remove the last stream letter ref
    _arg = _arg[0..-5]
    _arg << '"'
    $log.debug "COMPLEX ARG: #{_arg}"
    args << _arg
    args << "-shortest" # stop w/ first to stop
    args << "-f h264"
    args << "-" # output to stdout
    args << "2> /tmp/ffmpeg_err.out" # output errors
    return args
  end

  def clean_heartbeats
    l = @heartbeats.length
    @heartbeats = @heartbeats.select { |_,t| Time.now.to_i - t < 20 }
  end

  def has_sources?
    @heartbeats.length != 0
  end

  def stop_ffmpeg
    $log.info "Stopping FFMPEG"
    return false if @ffmpeg_pipe.nil?
    $log.info "Killing FFMPEG: #{@ffmpeg_pipe.pid}"
    Process.kill "TERM", @ffmpeg_pipe.pid
    $log.info "Waiting on kill: #{@ffmpeg_pipe.pid}"
    Process.wait @ffmpeg_pipe.pid, 0
    $log.info "Done waiting"
  end

  def heartbeat pipe_path
    $log.debug "Updating heartbeat: #{pipe_path}"
    @heartbeats[pipe_path] = Time.now.to_i
  end

  def ffmpeg_needs_restart?
    return true if stopped_getting_data?
    return true if added_new_connection?
    return true if ffmpeg_dead?
    false
  end

  def ffmpeg_dead?
    dead = true if @ffmpeg_pipe.nil?
    dead = dead || Process.getpgid(@ffmpeg_pipe.pid) == 1
    $log.info "FFMPEG DEAD" if dead && !@ffmpeg_pipe.nil?
    dead
  end

  def stopped_getting_data?
    @heartbeats.each do |pipe_path, last_beat|
      if Time.now.to_i - last_beat > 20
        $log.info "Data Timeout: #{pipe_path} #{last_beat}"
        return true 
      end
    end
    false
  end

  def added_new_connection?
    return false if @previous_keys == @heartbeats.keys
    $log.info "Connection change: #{@previous_keys} => #{@heartbeats.keys}"
    @previous_keys = @heartbeats.keys
    true
  end

end

class UnixPipeWriter

  include Messenger

  def initialize
    @pipes = {}
  end

  def cycle
    msg = pop_message
    handle_data msg[:conn_id], msg[:data] unless msg.nil?
  end

  def handle_data connection_id, data
    $log.debug "Unix Writer Handling: #{connection_id} #{data.length}"
    push_details connection_id, data
    push_to_pipe connection_id, data
  end

  def push_details connection_id, data
    push_message({ :pipe_path => path(connection_id), :data => data })
  end

  def push_to_pipe connection_id, data
    $log.debug "Unix push to pipe #{connection_id}: " + \
              "#{path(connection_id)} #{data.length}"
    ensure_fifo_exists path(connection_id)
    push_to_fifo path(connection_id), data
  end

  def push_to_fifo fifo_path, data
    $log.debug "Unix push to fifo: #{fifo_path} #{data.length}"
    @pipes[fifo_path].write data
    $log.debug "Unix done pushing to fifo"
  end

  def ensure_fifo_exists fifo_path
    $log.debug "Ensure fifo exists: #{fifo_path}"
    @pipes[fifo_path] ||= mkfifo fifo_path
  end

  def mkfifo fifo_path
    $log.info "Creating FIFO: #{fifo_path}"
    Fifo.new(fifo_path)
  end

  def path connection_id
    File.join(File.absolute_path('.'), 'data', connection_id.to_s)
  end

end

ffmpegger = FFMpegger.new
ffmpegger.bind_queues IQueue.new, IQueue.new
unix_pipe_writer = UnixPipeWriter.new
unix_pipe_writer.bind_queues IQueue.new, IQueue.new
socket_server = Server.new 'localhost', 8000, Handler
socket_server.bind_queues IQueue.new, IQueue.new

class ThreadedPipeline < Pipeline

  def start_threaded_cycle
    @messengers.each { |m| cycle_thread(m) }
    Thread.new do
      loop do
        @messengers.each_cons(2) do |a, b|
          begin
            m = a.out_queue.deq true
            b.in_queue << m
          rescue ThreadError
          end
        end
        sleep(0.1)
      end
    end.join
  end

  def cycle_thread obj
    if obj.respond_to? 'cycle'
      Thread.new do 
        loop do
          obj.cycle
          sleep 0.1
        end
      end
    end
  end

end

pipeline = ThreadedPipeline.new socket_server, unix_pipe_writer, ffmpegger, socket_server

pipeline.start_threaded_cycle
