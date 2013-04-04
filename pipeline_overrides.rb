require 'debugger'

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
        sleep 0.1
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

class FanPipe

  include Messenger

  def initialize create_new, get_key
    @create_new = create_new
    @get_key = get_key
    @handlers = {}
    bind_queues IQueue.new, IQueue.new
  end

  def handler_for_message m
    key = @get_key.call m
    raise "BAD KEY: #{m.keys} #{m[:conn_id]} #{key}" if key.nil? || key == ''
    if @handlers[key].nil?
      $log.info "Creating handler thread: #{key}"
      handler = @create_new.call
      $log.debug "Handler: #{handler}"
      @handlers[key] = handler
      Thread.new do
        # TODO: die if i dont get a msg for a while
        loop do
          $log.debug "Cycling handler in thread: #{key}"
          handler.cycle
          sleep 0.1
        end
      end
    end
    @handlers[key]
  end

  def push_to_thread m
    handler = handler_for_message m
    handler.in_queue << m
  end

  def cycle
    cycle_in_messages
    cycle_out_messages
  end

  def cycle_in_messages
    m = pop_message
    return false if m.nil?
    $log.debug "Pushing to thread"
    push_to_thread m
  end

  def cycle_out_messages
    @handlers.each do |conn_id, h|
      m = h.out_queue.deq
      next if m.nil?
      $log.debug "Cycle out [#{conn_id}]"
      out_queue << m
    end
  end

end
