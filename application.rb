require 'socketeer'
require 'fifo'
require 'logger'
require 'thread/pool'
require_relative 'pipeline_overrides'
require_relative 'unix_pipe_writer'
require_relative 'ffmpegger'

Thread.abort_on_exception = true

$log = Logger.new STDOUT
$log.level = Logger::DEBUG

ffmpegger = FFMpegger.new
ffmpegger.bind_queues IQueue.new, IQueue.new
socket_server = Server.new 'localhost', 8000, Handler
socket_server.bind_queues IQueue.new, IQueue.new

# first block creates a new handler instance
# second block returns handler key from message
fan_unix_pipe_writer = FanPipe.new(lambda { 
                                    w = UnixPipeWriter.new
                                    w.bind_queues IQueue.new, IQueue.new
                                    w
                                   },
                                   lambda { |m| m[:conn_id] })
pipeline = ThreadedPipeline.new(socket_server, 
                                fan_unix_pipe_writer, 
                                ffmpegger, 
                                socket_server

pipeline.start_threaded_cycle
