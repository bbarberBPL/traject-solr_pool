# frozen_string_literal: true

# Concurrency helpers included into example groups tagged :thread_safety.
module ThreadSafetyHelpers
  # Returns a lambda that blocks each caller until `count` callers have arrived,
  # so threads start their real work at the same moment.
  def cyclic_barrier(count)
    mutex = Mutex.new
    cond  = ConditionVariable.new
    arrived = 0
    lambda do
      mutex.synchronize do
        arrived += 1
        arrived >= count ? cond.broadcast : cond.wait(mutex)
      end
    end
  end
end
