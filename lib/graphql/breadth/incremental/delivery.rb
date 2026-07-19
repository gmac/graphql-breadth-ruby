# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    module Incremental
      class Delivery
        #: error_path
        attr_reader :path

        #: String?
        attr_reader :label

        #: Delivery?
        attr_reader :parent

        #: (error_path, ?String?, ?parent: Delivery?) -> void
        def initialize(path, label = nil, parent: nil)
          @path = path.freeze
          @label = label
          @parent = parent
        end

        #: (error_path) -> bool
        def path_prefix_of?(path)
          return false if @path.length > path.length

          i = 0
          while i < @path.length
            return false unless @path[i] == path[i]

            i += 1
          end

          true
        end
      end
    end
  end
end
