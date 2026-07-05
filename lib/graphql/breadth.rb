# typed: true
# frozen_string_literal: true

require "graphql"
require "set"

module GraphQL
  module Breadth
    class << self
      #: Proc?
      attr_accessor :on_report_error

      #: (Exception) -> void
      def report_error(error)
        on_report_error&.call(error)
      end

      #: -> bool
      def async_enabled?
        @async_enabled == true
      end

      #: -> void
      def enable_async!
        return if async_enabled?

        require "async"
        require "async/barrier"
        require "async/queue"
        require "async/semaphore"

        @async_enabled = true
      rescue LoadError => e
        @async_enabled = false
        raise ImplementationError, "Async lazy loaders require the `async` gem. Add `gem \"async\"` to your bundle. #{e.message}"
      end
    end

    EMPTY_OBJECT = {}.freeze
    EMPTY_ARRAY = [].freeze
    EMPTY_SET = Set.new.freeze

    # Stub a few early constants for Sorbet typing.
    class Executor
      #: [ObjectType < Object?]
      class ExecutionField; end
    end

    #: type error_path = Array[String | Integer]
    #: type invalidated_indices = Hash[Integer, StandardError?]
    #: type graphql_arguments = Hash[String | Symbol, untyped]
    #: type loader_args = Hash[Symbol, untyped]
    #: type graphql_result = Hash[String, untyped]
    #: type variables_hash = Hash[String, untyped]
    #: type selection_node = GraphQL::Language::Nodes::Field | GraphQL::Language::Nodes::InlineFragment | GraphQL::Language::Nodes::FragmentSpread
  end
end

require_relative "breadth/util"
require_relative "breadth/errors"
require_relative "breadth/authorization"
require_relative "breadth/executor/execution_promise"
require_relative "breadth/lazy_loader"
require_relative "breadth/tracer"
require_relative "breadth/field_resolvers"
require_relative "breadth/directive_resolvers"
require_relative "breadth/subscription_response_stream"
require_relative "breadth/has_breadth_resolver"
require_relative "breadth/introspection"
require_relative "breadth/executor"
require_relative "breadth/incremental"
require_relative "breadth/version"
