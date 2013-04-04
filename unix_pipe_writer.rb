require 'timeout'

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
    push_to_fifo_block fifo_path, data
    #push_to_fifo_nonblock fifo_path, data
  end

  def push_to_fifo_block fifo_path, data
    $log.debug "Unix push to fifo: #{fifo_path} #{data.length}"
    begin
      status = Timeout::timeout(10) {
        @pipes[fifo_path].write data
      }
      $log.debug "Unix done pushing to fifo: #{fifo_path} #{data.length}"
    rescue Timeout::Error
      $log.debug "TIMEOUT Unix push to fifo: #{fifo_path}"
    end
  end

  def push_to_fifo_nonblock fifo_path, data
    $log.debug "Unix push to fifo: #{fifo_path} #{data.length}"
    begin
      @pipes[fifo_path].instance_eval do
        @pipe.write_nonblock data
      end
    rescue IO::WaitReadable, EOFError, IOError, Errno::EAGAIN => ex
      # not ready for write, oh wells, skip this data
      $log.info "NOT ready for writes: #{fifo_path}: #{ex}"
      return
    end
    $log.debug "Unix done pushing to fifo: #{fifo_path} #{data.length}"
  end

  def ensure_fifo_exists fifo_path
    $log.debug "Ensure fifo exists: #{fifo_path}"
    unless File.exists? fifo_path
      $log.debug "Closing missing FIFO: #{fifo_path}"
      @pipes[fifo_path].close if @pipes[fifo_path] rescue
      @pipes.delete fifo_path
    end
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
