
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
