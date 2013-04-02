require 'socketeer'
require 'fifo'

class FFMpegger

  include Messenger

  @@ffmpeg_command = '~/bin/ffmpeg'

  def initialize
    @heartbeats = {}
    @previous_keys = []
  end

  def cycle
    msg = pop_message
    handle_data msg[:pipe_path], msg[:data] unless msg.nil?
  end

  def handle_data pipe_path, data
    heartbeat pipe_path
    restart_ffmpeg if ffmpeg_needs_restart?
    push_new_ffmpeg_data
  end

  private

  def push_new_ffmpeg_data
    data = @ffmpeg_output.read_nonblock 4096 rescue nil
    push_message({:data=>data}) unless data.nil?
  end

  def restart_ffmpeg
    stop_ffmpeg
    start_ffmpeg
  end

  def start_ffmpeg
    clean_heartbeats
    ffmpeg_input, @ffmpeg_output = IO.pipe
    @ffmpeg_pid = fork {
      ffmpeg_input.close # nothing to write
      $stdout.reopen @ffmpeg_output
      exec @@ffmpeg_command, *ffmpeg_args
    }
  end

  def ffmpeg_args
    # TODO
    []
  end

  def clean_heartbeats
    @heartbeats.select { |_,t| t - Time.now.to_i > 20 }
  end

  def stop_ffmpeg
    return false if @ffmpeg_pid.nil?
    Process.kill @ffmpeg_pid
  end

  def heartbeat pipe_path
    @heartbeats[pipe_path] = Time.now.to_i
  end

  def ffmpeg_needs_restart?
    return true if stopped_getting_data?
    return true if added_new_connection?
  end

  def stopped_getting_data?
    @heartbeats.each do |pipe_path, last_beat|
      return true if last_beat - Time.now.to_i > 20
    end
    false
  end

  def added_new_connection?
    return false if @previous_keys == @heartbeats.keys
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
    push_to_pipe connection_id, data
    push_details connection_id, data
  end

  def push_details connection_id, data
    push_message({ :pipe_path => path(connection_id), :data => data })
  end

  def push_to_pipe connection_id, data
    ensure_fifo_exists connection_id
    push_to_fifo path(connection_id), data
  end

  def push_to_fifo fifo_path, data
    @pipes[fifo_path].write data
  end

  def ensure_fifo_exists connection_id
    @pipes[path(connection_id)] = mkfifo path connection_id
  end

  def mkfifo fifo_path
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
