require 'timeout'

class UnixPipeWriter

  include Messenger

  def initialize
    @pipes = {}
  end

  def cycle
    1000.times do
      msg = pop_message
      return if msg.nil?
      handle_message msg
    end
  end

  def handle_message msg
    return false if msg.nil?
    if msg[:conn_id] && msg[:data]
      handle_data msg[:conn_id], msg[:data] unless msg.nil?
    elsif msg[:source_key] && msg[:pipe_message]
      $log.debug "PIPE message: #{msg}"
      case msg[:pipe_message]
      when :new_conn
        # there is a new connection joining us, drop our queue
        # only act if we weren't the new person on the block
        clear_queue unless msg[:source_key] == msg[:target_key] 
      else
        $log.warn "Unhandled pipe msg: #{msg[:pipe_message]}"
      end
    end
  end

  def handle_data connection_id, data
    $log.debug "Unix Writer Handling: #{connection_id} #{data.length}"
    # push details first so that the ffmpegger knows to start
    push_details connection_id, data
    push_to_pipe connection_id, data
  end

  def push_details connection_id, data
    $log.debug "Pipe Pushing details: #{connection_id}"
    push_message({ :pipe_path => path(connection_id) })
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
    #push_to_fifo_drop_stale_queue fifo_path, data
  end

  def push_to_fifo_drop_stale_queue fifo_path, data
    begin
      status = Timeout::timeout(timeout) {
        push_to_fifo_block fifo_path, data
      }
    rescue Timeout::Error
      $log.debug "TIMEOUT Unix push to fifo: #{fifo_path}"
      clear_queue
      false
    end
    true
  end

  def push_to_fifo_block fifo_path, data
    $log.debug "Unix push to fifo: #{fifo_path} #{data.length}"
    @pipes[fifo_path].write data
    $log.debug "Unix done pushing to fifo: #{fifo_path} #{data.length}"
    true
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

  def clear_queue
    # reaching into internals
    $log.debug "Unix Pipe Clearing Queue"
    in_queue.clear
  end

end
