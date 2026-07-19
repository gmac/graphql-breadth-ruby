# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    module Incremental
      module ExecutorSupport
        ForkRuntime = Data.define(
          :schema,
          :resolvers,
          :query,
          :context,
          :input,
          :document,
          :provided_variables,
          :context_value,
          :tracers,
          :authorization_class,
          :loader_cache
        )

        #: -> ForkRuntime
        def incremental_fork_runtime
          ForkRuntime.new(
            schema: @schema,
            resolvers: @resolvers,
            query: @query,
            context: @context,
            input: @input,
            document: @document,
            provided_variables: @provided_variables,
            context_value: @context_value,
            tracers: @tracers,
            authorization_class: @authorization_class,
            loader_cache: (@loader_cache ||= {}),
          )
        end
      end
    end
  end
end
