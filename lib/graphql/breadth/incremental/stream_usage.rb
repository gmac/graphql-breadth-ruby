# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    module Incremental
      class StreamUsage
        #: String?
        attr_reader :label

        #: Integer
        attr_reader :initial_count

        #: (?String?, initial_count: Integer) -> void
        def initialize(label = nil, initial_count:)
          @label = label
          @initial_count = initial_count
        end
      end
    end
  end
end
