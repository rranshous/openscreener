require 'socketeer'
require 'fifo'
require 'logger'

$log = Logger.new STDOUT

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
  end

  def handle_data pipe_path, data
    $log.debug "Handle Data: #{pipe_path} #{data.length}"
    heartbeat pipe_path
    restart_ffmpeg if ffmpeg_needs_restart?
  end

  private

  def push_new_ffmpeg_data
    data = @ffmpeg_output.read_nonblock 4096 rescue nil
    return false if data.nil?
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
    clean_heartbeats
    ffmpeg_input, @ffmpeg_output = IO.pipe
    args = ffmpeg_args
    puts "FFMPEG_ARGS: #{args}"
    @ffmpeg_pid = fork {
      ffmpeg_input.close # nothing to write
      $stdout.reopen @ffmpeg_output
      $log.info "Starting FFMPEG PROC"
      exec @@ffmpeg_command, *args
    }
    $log.info "FFMPEG PID: #{@ffmpeg_pid}"
  end

  def ffmpeg_args
    args = []
    @heartbeats.each do |fifo_path, last_heartbeat|
      args << '-i'
      args << fifo_path
    end
    args << '-filter_complex'
    _arg = '"'

    # output a square video for simplicity
    output_width = output_height = 1024
    number_of_inputs = @heartbeats.length
    cells_per_side = Math.sqrt(number_of_inputs).ceil # round up
    cell_size = output_width / cells_per_side
    $log.debug "OUTPUT WIDTH: #{output_width}"
    $log.debug "NUMBER OF INPUTS: #{number_of_inputs}"
    $log.debug "CELLS PER SIDE: #{cells_per_side}"
    $log.debug "CELL SIZE: #{cell_size}"

    # scale our inputs
    stream_letter = nil
    @heartbeats.keys.each_with_index do |_, i|
      stream_letter = (97 + i).chr
      _arg << "[#{i}:0]scale=#{cell_size}:-1[#{stream_letter}];"
    end

    # line our inputs up
    last_new_stream_letter = stream_letter
    @heartbeats.keys.each_with_index do |fifo_path, i|
      new_stream_letter = (last_new_stream_letter.ord + 1).chr
      input_stream_letter = (97 + i).chr
      row_i = i % cells_per_side
      col_i = i % (i * cells_per_side) rescue 0
      _arg << "[#{last_new_stream_letter}][#{input_stream_letter}]" + \
              "overlay=#{cell_size*row_i}:h#{cell_size*col_i}[#{new_stream_letter}];"
      last_new_stream_letter = new_stream_letter
    end
    _arg << '"'
    $log.debug "COMPLEX ARG: #{_arg}"
    args << _arg
    args << "-shortest" # stop w/ first to stop
    args << "-" # output to stdout
    return args
  end

  def clean_heartbeats
    $log.debug "Cleaning Heartbeats: #{@heartbeats}"
    @heartbeats = @heartbeats.select { |_,t| t - Time.now.to_i < 20 }
    $log.debug "Remaining heartbeats: #{@heartbeats}"
  end

  def stop_ffmpeg
    $log.info "Stopping FFMPEG: #{@ffmpeg_pid}"
    return false if @ffmpeg_pid.nil?
    $log.info "Killing FFMPEG: #{@ffmpeg_pid}"
    Process.kill @ffmpeg_pid
  end

  def heartbeat pipe_path
    $log.debug "Updating heartbeat: #{pipe_path}"
    @heartbeats[pipe_path] = Time.now.to_i
  end

  def ffmpeg_needs_restart?
    return true if stopped_getting_data?
    return true if added_new_connection?
  end

  def stopped_getting_data?
    @heartbeats.each do |pipe_path, last_beat|
      if last_beat - Time.now.to_i > 20
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
    push_to_pipe connection_id, data
    push_details connection_id, data
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
    $log.debug "Unix push to file: #{fifo_path} #{data.length}"
    @pipes[fifo_path].write data
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

pipeline = Pipeline.new socket_server, unix_pipe_writer, ffmpegger, socket_server

loop do
  pipeline.cycle
end
