# typed: true
# frozen_string_literal: true

require_relative "incremental/defer_usage"
require_relative "incremental/delivery"
require_relative "incremental/deferred_delivery"
require_relative "incremental/stream_delivery"
require_relative "incremental/stream_usage"
require_relative "incremental/partitioner"
require_relative "incremental/selection"
require_relative "incremental/entry"
require_relative "incremental/work"
require_relative "incremental/deferred_work"
require_relative "incremental/stream_work"
require_relative "incremental/execution_scope"
require_relative "incremental/result"
require_relative "incremental/publisher"
require_relative "incremental/executor_support"
require_relative "incremental/execution_fork"
require_relative "incremental/coordinator"
require_relative "incremental/context"

module GraphQL
  module Breadth
    module Incremental
    end

    Executor.include(Incremental::ExecutorSupport)
  end
end
