# typed: true

module Async
  class TimeoutError < StandardError; end

  class Barrier
    def initialize(parent: T.unsafe(nil)); end
    def async(*arguments, parent: T.unsafe(nil), **options, &block); end
    def empty?; end
    def wait; end
    def stop; end
  end

  class Queue
    def initialize(parent: T.unsafe(nil)); end
    def <<(item); end
    def dequeue; end
  end

  class Semaphore
    def initialize(limit = T.unsafe(nil), parent: T.unsafe(nil)); end
    def async(*arguments, parent: T.unsafe(nil), **options, &block); end
    def acquire; end
    def limit; end
    def release; end
  end

  class Task
    def wait; end
    def with_timeout(duration, exception = T.unsafe(nil), message = T.unsafe(nil), &block); end
  end
end

module Kernel
  def Sync(annotation: T.unsafe(nil), &block); end
end
