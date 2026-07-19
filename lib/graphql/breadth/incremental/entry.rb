# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    module Incremental
      Entry = Data.define(:work, :object, :path, :index) do
        def initialize(work:, object:, path:, index:)
          super(work:, object:, path: path.freeze, index:)
        end
      end
    end
  end
end
