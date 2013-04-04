
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
        sleep 0.01
      end
    end.join
  end

  def cycle_thread obj
    if obj.respond_to? 'cycle'
      Thread.new do 
        loop do
          obj.cycle
          sleep 0.01
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
    if @threads[key].nil?
      handler = @create_new.call
      @handlers[key] = handler
      Thread.new do
        loop do
          handler.cycle
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
    return false if n.nil?
    push_to_thread m
  end

  def cycle_out_messages
    @handlers.each do |h|
      in_queue << h.out_queue.deq rescue nil
    end
  end

end
