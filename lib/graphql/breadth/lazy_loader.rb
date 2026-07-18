# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    #: [ContextType < GraphQL::Query::Context]
    class LazyLoader
      AsyncSettings = Data.define(:enabled, :limit, :resource, :timeout, :throttle) do
        alias_method :enabled?, :enabled
      end

      # Snapshots a loader's promised elements before execution resets loader state.
      Batch = Data.define(:loader, :elements) do
        def aborted?
          elements.all? do |element|
            case element
            when Executor::ExecutionField
              element.scope.aborted_subtree?
            when Executor::ExecutionScope
              element.aborted_subtree?
            else
              raise ImplementationError, "Invalid lazy element: #{element.inspect}"
            end
          end
        end
      end

      class LazyFulfillment
        #: Executor::LazyElement
        attr_reader :element

        #: Array[untyped]
        attr_reader :keys

        #: Array[untyped]
        attr_reader :identities

        #: Hash[untyped, untyped]?
        attr_reader :eager_values

        #: Executor::ExecutionPromise
        attr_reader :promise

        #: (
        #|   element: Executor::LazyElement,
        #|   keys: Array[untyped],
        #|   identities: Array[untyped],
        #|   ?eager_values: Hash[untyped, untyped]?,
        #|   ?pre_deferred: Executor::ExecutionPromise::Deferred?,
        #| ) -> void
        def initialize(element:, keys:, identities:, eager_values: nil, pre_deferred: nil)
          @element = element
          @keys = keys
          @identities = identities
          @eager_values = eager_values
          @resolver = pre_deferred&.resolver
          @promise = pre_deferred&.promise || Executor::ExecutionPromise.new { |resolve, _reject| @resolver = resolve }
        end

        #: (untyped) -> void
        def resolve(results)
          @resolver.call(results)
        end
      end

      KEY_OMISSION = Object.new.freeze

      DEFAULT_ASYNC_SETTINGS = AsyncSettings.new(
        enabled: false,
        limit: nil,
        resource: nil,
        timeout: nil,
        throttle: nil,
      ).freeze

      class << self
        #: (?limit: Integer?, ?resource: Symbol?, ?timeout: Numeric?, ?throttle: async_throttle?) -> void
        def async(limit: 8, resource: nil, timeout: nil, throttle: nil)
          unless GraphQL::Breadth.async_enabled?
            Kernel.raise ImplementationError, "Async lazy loaders require `GraphQL::Breadth.enable_async!` during initialization."
          end

          raise ArgumentError, "Lazy async limit must be positive" unless limit.nil? || limit > 0
          raise ArgumentError, "Lazy async timeout must be positive" unless timeout.nil? || timeout > 0

          @async_settings = AsyncSettings.new(
            enabled: true,
            limit: limit,
            resource: resource || name&.to_sym || :"lazy_loader_#{object_id}",
            timeout: timeout,
            throttle: throttle,
          ).freeze
        end

        #: -> AsyncSettings
        def async_settings
          @async_settings || DEFAULT_ASYNC_SETTINGS
        end
      end

      #: Hash[untyped, untyped]
      attr_reader :pending_keys_by_identity

      #: Hash[untyped, untyped]
      attr_reader :results_by_identity

      #: Array[LazyFulfillment]
      attr_reader :promised

      #: -> void
      def initialize
        @pending_keys_by_identity = {}
        @results_by_identity = {}
        @promised = []
        @async_context = nil
      end

      #: -> Batch
      def to_batch
        Batch.new(loader: self, elements: promised.map(&:element))
      end

      #: -> bool
      def map?
        false
      end

      #: -> bool
      def resolve_one?
        false
      end

      #: -> AsyncSettings
      def async_settings
        self.class.async_settings
      end

      #: (?resource: Symbol?, ?limit: Integer?, ?timeout: Numeric?, ?throttle: async_throttle?) ?{ -> untyped } -> Executor::LazyAsync::Future
      def async(resource: nil, limit: nil, timeout: nil, throttle: nil, &block)
        unless @async_context
          raise ImplementationError, "LazyLoader#async requires the loader class to opt into async features via `async(...)`."
        end

        @async_context.async(resource: resource, limit: limit, timeout: timeout, throttle: throttle, &block)
      end

      #: [T, U] (Enumerable[T], ?resource: Symbol?, ?limit: Integer?, ?timeout: Numeric?, ?throttle: async_throttle?) ?{ (T) -> U } -> Array[U]
      def async_map(collection, resource: nil, limit: nil, timeout: nil, throttle: nil, &block)
        unless @async_context
          raise ImplementationError, "LazyLoader#async_map requires the loader class to opt into async features via `async(...)`."
        end

        @async_context.async_map(collection, resource: resource, limit: limit, timeout: timeout, throttle: throttle, &block)
      end

      #: (Array[untyped], ContextType) -> void
      def perform(_keys, _context)
        raise NotImplementedError, "LazyLoader#perform must be implemented."
      end

      #: (Array[untyped], ContextType) -> Array[untyped]
      def perform_map(_keys, _context)
        raise NotImplementedError, "LazyLoader#perform_map must be implemented."
      end

      #: (untyped) -> untyped
      def identity_for(key)
        key
      end

      #: (untyped, untyped) -> void
      def fulfill_key(key, result)
        @results_by_identity[identity_for(key)] = result
      end

      #: (untyped, untyped) -> void
      def fulfill_identity(identity, result)
        @results_by_identity[identity] = result
      end

      #: (
      #|   element: Executor::LazyElement,
      #|   keys: Array[untyped],
      #|   ?eager_values: Hash[untyped, untyped]?,
      #|   ?load_nil_keys: bool,
      #|   ?pre_deferred: Executor::ExecutionPromise::Deferred?,
      #| ) -> Executor::ExecutionPromise
      def load(element:, keys:, eager_values: nil, load_nil_keys: false, pre_deferred: nil)
        eager_values = nil if eager_values&.empty?
        compact = !load_nil_keys
        pending = @pending_keys_by_identity
        results = @results_by_identity

        raise ImplementationError, "Provide exactly one key when resolving a single result" if resolve_one? && keys.size != 1

        identities = keys.map do |key|
          next KEY_OMISSION if (compact && key.nil?) || eager_values&.key?(key)

          identity = identity_for(key)
          pending[identity] ||= key unless results.key?(identity)
          identity
        end

        @promised << LazyFulfillment.new(
          element: element,
          keys: keys,
          identities: identities,
          eager_values: eager_values,
          pre_deferred: pre_deferred,
        )
        @promised.last.promise
      end

      #: (LazyFulfillment) -> untyped
      def collect_results(fulfillment)
        identities = fulfillment.identities
        results = @results_by_identity

        return results[identities.first] if resolve_one?

        if (eager_values = fulfillment.eager_values)
          keys = fulfillment.keys
          Array.new(identities.size) do |i|
            identity = identities[i]
            identity.equal?(KEY_OMISSION) ? eager_values[keys[i]] : results[identity]
          end
        else
          identities.map { results[_1] }
        end
      end

      #: (ContextType, ?async_context: Executor::LazyAsync::LoaderContext?) -> void
      def execute!(context, async_context: nil)
        previous_async_context = @async_context
        @async_context = async_context
        fulfillments = @promised
        unless @pending_keys_by_identity.empty?
          pending_loader_keys = @pending_keys_by_identity.values

          if map?
            pending_loader_identities = @pending_keys_by_identity.keys
            reset!

            mapped_results = perform_map(pending_loader_keys, context)
            unless pending_loader_keys.size == mapped_results.size
              raise ImplementationError, "Wrong number of results. Expected #{pending_loader_keys.size}, got #{mapped_results.size}"
            end

            i = 0
            while i < pending_loader_identities.length
              @results_by_identity[pending_loader_identities[i]] = mapped_results[i]
              i += 1
            end
          else
            reset!
            perform(pending_loader_keys, context)
          end
        else
          reset!
        end

        fulfillments.each { |fulfillment| fulfillment.resolve(collect_results(fulfillment)) }
      ensure
        @async_context = previous_async_context
      end

      #: -> void
      def reset!
        @pending_keys_by_identity.clear
        @promised = []
      end
    end
  end
end
