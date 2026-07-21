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

        #: [T, U] (Enumerable[T], LazyLoader::AsyncSettings) { (T) -> U } -> Array[U]
        def execute_stream_sources(sources, settings, &block)
          if settings.enabled?
            execute_async_collection(sources, settings, &block)
          else
            sources.map(&block)
          end
        end
      end
    end
  end
end
