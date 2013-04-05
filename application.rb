require 'socketeer'
require 'fifo'
require 'logger'
require_relative 'pipeline_overrides'
require_relative 'unix_pipe_writer'
require_relative 'ffmpegger'

Thread.abort_on_exception = true

$log = Logger.new STDOUT
$log.level = Logger::DEBUG

class IQueue
  def deq *args
    r = super
    if length > 10
      $log.warn "Queue Length [#{self}]: #{self.length}: #{r.keys}"
    end
    r
  end
end

class Handler
  def write data
    return if data.nil?
    $log.debug "Writing"
    @socket.write data
    $log.debug "DONE writing"
  end
end

ffmpegger = FFMpegger.new
ffmpegger.bind_queues IQueue.new, IQueue.new
socket_server = Server.new '0.0.0.0', 8000, Handler
socket_server.bind_queues IQueue.new, IQueue.new

# first block creates a new handler instance
# second block returns handler key from message
fan_unix_pipe_writer = FanPipe.new(
  lambda { 
    w = UnixPipeWriter.new
    w.bind_queues IQueue.new, IQueue.new
    w
  },
  lambda { |m| m[:conn_id] })

pipeline = Pipeline.new(socket_server, 
                        fan_unix_pipe_writer, 
                        ffmpegger, 
                        socket_server)

loop do
  pipeline.cycle
end
