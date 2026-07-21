# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    module Incremental
      class Work
        #: bool
        attr_reader :announced

        #: bool
        attr_reader :executed

        def initialize
          @announced = false
          @executed = false
          @cancelled = false
        end

        #: -> bool
        def announced?
          @announced
        end

        #: -> bool
        def executed?
          @executed
        end

        #: -> bool
        def cancelled?
          @cancelled
        end

        #: -> void
        def announce!
          @announced = true
        end

        #: -> void
        def finish!
          @executed = true
        end

        #: -> void
        def cancel!
          @cancelled = true
          @executed = true
        end

        #: -> bool
        def ready?
          raise NotImplementedError
        end

        #: -> bool
        def announceable?
          ready?
        end

        #: -> untyped
        def cohort_key
          self
        end
      end
    end
  end
end
