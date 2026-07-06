# frozen_string_literal: true

require "thread"

module Example
  class EventBus
    def initialize
      @mutex = Mutex.new
      @subscribers = []
    end

    def subscribe
      queue = Queue.new

      @mutex.synchronize do
        @subscribers << queue
      end

      Enumerator.new do |events|
        begin
          loop do
            events << queue.pop
          end
        ensure
          @mutex.synchronize do
            @subscribers.delete(queue)
          end
        end
      end
    end

    def publish(card_id:)
      event = nil
      subscribers = nil

      @mutex.synchronize do
        event = { "card_id" => card_id }
        subscribers = @subscribers.dup
      end

      subscribers.each { |queue| queue << event }

      {
        "event" => event,
        "subscribers" => subscribers.length,
      }
    end
  end
end
