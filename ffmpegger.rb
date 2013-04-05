require 'socketeer'

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
    $log.debug "Checking for FFMPEG data: #{ffmpeg_dead?}"
    begin
      unless @ffmpeg_pipe.nil?
        data = ''
        loop do
          data << @ffmpeg_pipe.read_nonblock(4096)
        end
      else
        $log.debug "CANT check data, no pipe"
      end
    rescue IO::WaitReadable, EOFError
      # nothing left to read
    end
    return false if data.nil? || data.empty?
    $log.debug "FFMPEG Data: #{data.length}"
    push_message({:data=>data}) unless data.nil?
  end

  def restart_ffmpeg
    $log.info "FFMPEG Restart"
    stop_ffmpeg
    clean_heartbeats
    start_ffmpeg
  end

  def start_ffmpeg
    $log.info "FFMPEG Starting"
    unless has_sources?
      $log.info "Not starting FFMPEG, no sources"
      return false
    end
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
    #args << '-v debug'
    @heartbeats.each do |fifo_path, last_heartbeat|
      args << "-re" # native frame rate
      args << "-i #{fifo_path}"
    end
    args << '-filter_complex'

    # output a square video for simplicity
    output_width = output_height = 800
    number_of_inputs = @heartbeats.length
    cells_per_side = Math.sqrt(number_of_inputs).ceil # round up
    cell_size = output_width / cells_per_side
    $log.debug "OUTPUT WIDTH: #{output_width}"
    $log.debug "NUMBER OF INPUTS: #{number_of_inputs}"
    $log.debug "CELLS PER SIDE: #{cells_per_side}"
    $log.debug "CELL SIZE: #{cell_size}"

    _arg = '"'
    # create initial nothing background
    _arg << "color=size=#{output_width}x#{output_height}[background];"

    # scale our inputs
    initial_char = 'a'
    stream_letter = initial_char.dup
    @heartbeats.keys.each_with_index do |_, i|
      _arg << "[#{i}:0]setpts=PTS-STARTPTS,scale=#{cell_size}:-1[#{stream_letter}];"
      stream_letter = (stream_letter.ord + 1).chr
    end

    # line our inputs up
    # [last_output][next_input]overlay=0+(800-w)/2:0+(800-h)/2[new_output]
    # the initial last output will be the background, followed by the new output
    # new output will be initiall the next letter in the alphabet after the last
    # stream letter
    # next input will be a-<n>
    last_output = 'background'
    new_output = stream_letter.dup
    next_input = initial_char.dup
    @heartbeats.keys.each_with_index do |fifo_path, i|
      col_i, row_i = self.class.cell_location i, cells_per_side
      _arg << "[#{last_output}][#{next_input}]" + \
              "overlay=" + \
              "#{cell_size*col_i}+(#{cell_size}-w)/2:" + \
              "#{cell_size*row_i}+(#{cell_size}-h)/2" + \
              "[#{new_output}];"
      last_output = new_output
      new_output = (new_output.ord + 1).chr
      next_input = (next_input.ord + 1).chr
    end
    # remove the last stream letter ref
    _arg = _arg[0..-5]
    _arg << '"'
    $log.debug "COMPLEX ARG: #{_arg}"
    args << _arg
    args << "-an" # no audio
    #args << "-framedrop!" # ?
    args << "-preset ultrafast" # try and move it along
    args << "-vbsf h264_mp4toannexb" # mpeg2 transport stream
    args << "-vcodec h264" # h264 encoded video
    args << "-f mpegts"
    args << "-" # output to stdout
    args << "2> /tmp/ffmpeg_err.out" # output errors
    return args
  end

  def self.cell_location i, cells_per_side
    row_i = i / cells_per_side
    col_i = i % cells_per_side rescue 0
    $log.debug "COLI[#{i}]: #{col_i}"
    $log.debug "ROWI[#{i}]: #{row_i}"
    return [col_i, row_i]
  end

  def clean_heartbeats
    l = @heartbeats.length
    # clear old or missing
    @heartbeats = @heartbeats.select { |_,t| Time.now.to_i - t < 20 }
    @heartbeats = @heartbeats.select { |p,_| File.exists? p }
  end

  def has_sources?
    @heartbeats.length != 0
  end

  def stop_ffmpeg
    $log.info "Stopping FFMPEG"
    return false if @ffmpeg_pipe.nil?
    if ffmpeg_dead?
      $log.info "NOT stopping, already dead"
      return
    end
    $log.info "Killing FFMPEG: #{@ffmpeg_pipe.pid}"
    Process.kill "TERM", @ffmpeg_pipe.pid rescue Errno::ESRCH
    $log.info "Waiting on kill: #{@ffmpeg_pipe.pid}"
    Process.wait @ffmpeg_pipe.pid, 0 rescue Errno::ECHILD
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
    begin
      dead = dead || Process.getpgid(@ffmpeg_pipe.pid) == 1
    rescue Errno::ESRCH
      dead = true
    end
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
