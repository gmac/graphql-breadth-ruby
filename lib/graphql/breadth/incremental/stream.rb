# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    module Incremental
      module Stream
        Chunk = Data.define(:items, :complete) do
          #: (items: Array[untyped], ?complete: bool) -> void
          def initialize(items:, complete: false)
            raise ArgumentError, "Stream chunks must contain an Array" unless items.is_a?(Array)

            super(items: items.freeze, complete:)
          end
        end

        Batch = Data.define(:items_by_position, :completed_positions, :errors_by_position) do
          #: -> bool
          def empty?
            items_by_position.empty? && completed_positions.empty? && errors_by_position.empty?
          end
        end

        Advance = Data.define(:items, :complete, :error)

        # Enumerator executes its producer block in an internal Fiber that does not
        # inherit Async::Task fiber storage. Drive #each from a managed Fiber so
        # async work inside the producer sees the task advancing it.
        class EnumeratorCursor
          include Enumerable

          COMPLETE = Object.new.freeze
          CloseSignal = Class.new(Exception)

          #: (Enumerator, ?blocking: bool) -> void
          def initialize(enumerator, blocking: false)
            @enumerator = enumerator
            @blocking = blocking
            @fiber = nil
            @complete = false
          end

          #: () { (untyped) -> void } -> EnumeratorCursor
          def each
            return enum_for(:each) unless block_given?

            loop { yield self.next }
          rescue StopIteration
            self
          end

          #: -> untyped
          def next
            raise StopIteration if @complete

            @fiber ||= Fiber.new(blocking: @blocking) do |task|
              install_async_task(task)
              @enumerator.each do |value|
                task = Fiber.yield(value)
                install_async_task(task)
              end
              COMPLETE
            end

            value = @fiber.resume(current_async_task)
            if value.equal?(COMPLETE)
              @complete = true
              raise StopIteration
            end

            value
          end

          #: -> void
          def close
            return if @complete

            @complete = true
            @fiber&.raise(CloseSignal) if @fiber&.alive?
          rescue CloseSignal, FiberError
            nil
          ensure
            @enumerator.close if @enumerator.respond_to?(:close)
          end

          private

          #: -> untyped
          def current_async_task
            ::Async::Task.current? if defined?(::Async::Task)
          end

          #: (untyped) -> void
          def install_async_task(task)
            Fiber.current.async_task = task if Fiber.current.respond_to?(:async_task=)
          end
        end

        class << self
          #: (Array[untyped], ?complete: bool) -> Chunk
          def chunk(items, complete: false)
            Chunk.new(items:, complete:)
          end

          #: (
          #|   Enumerator,
          #|   ?async: bool,
          #|   ?limit: Integer?,
          #|   ?resource: Symbol?,
          #|   ?timeout: Numeric?,
          #|   ?throttle: async_throttle?,
          #| ) -> Collective
          def collective(enumerator, async: false, limit: 8, resource: nil, timeout: nil, throttle: nil)
            Collective.new(
              enumerator,
              async_settings: build_async_settings(
                async:,
                limit:,
                resource: resource || :graphql_breadth_collective_stream,
                timeout:,
                throttle:,
              ),
            )
          end

          #: (
          #|   Array[Enumerator?],
          #|   ?async: bool,
          #|   ?limit: Integer?,
          #|   ?resource: Symbol?,
          #|   ?timeout: Numeric?,
          #|   ?throttle: async_throttle?,
          #| ) -> Positional
          def positional(enumerators, async: false, limit: 8, resource: nil, timeout: nil, throttle: nil)
            Positional.new(
              enumerators,
              async_settings: build_async_settings(
                async:,
                limit:,
                resource: resource || :graphql_breadth_positional_stream,
                timeout:,
                throttle:,
              ),
            )
          end

          #: (Array[untyped]) -> Eager
          def eager(values)
            Eager.new(values)
          end

          #: (untyped) -> Session
          def normalize(value)
            case value
            when Session
              value
            when Array
              positional(value)
            else
              if value.respond_to?(:next)
                collective(value)
              else
                raise ImplementationError, "FieldResolver#stream must return an Enumerator or an Array of positional Enumerators"
              end
            end
          end

          private

          #: (
          #|   async: bool,
          #|   limit: Integer?,
          #|   resource: Symbol,
          #|   timeout: Numeric?,
          #|   throttle: async_throttle?,
          #| ) -> LazyLoader::AsyncSettings
          def build_async_settings(async:, limit:, resource:, timeout:, throttle:)
            if async && !GraphQL::Breadth.async_enabled?
              raise ImplementationError, "Async streams require `GraphQL::Breadth.enable_async!` during initialization."
            end
            raise ArgumentError, "Stream async limit must be positive" unless limit.nil? || limit.positive?
            raise ArgumentError, "Stream async timeout must be positive" unless timeout.nil? || timeout.positive?

            LazyLoader::AsyncSettings.new(
              enabled: async,
              limit: async ? limit : nil,
              resource:,
              timeout:,
              throttle:,
            ).freeze
          end
        end

        class Session
          NO_STATIC_VALUE = Object.new.freeze

          #: LazyLoader::AsyncSettings
          attr_reader :async_settings

          #: Integer?
          attr_reader :cardinality

          #: (LazyLoader::AsyncSettings) -> void
          def initialize(async_settings)
            @async_settings = async_settings
            @cardinality = nil
            @buffers = nil
            @completed = nil
            @completion_reported = nil
            @errors = nil
            @static_values = nil
            @closed = false
          end

          #: (Integer) -> Session
          def bind(cardinality)
            if @cardinality && @cardinality != cardinality
              raise ImplementationError, "Stream session is already bound to #{@cardinality} positions, cannot bind to #{cardinality}"
            end

            unless @cardinality
              @cardinality = cardinality
              @buffers = Array.new(cardinality) { [] }
              @completed = Array.new(cardinality, false)
              @completion_reported = Array.new(cardinality, false)
              @errors = Array.new(cardinality)
              @static_values = Array.new(cardinality, NO_STATIC_VALUE)
              after_bind
            end
            self
          end

          #: (Integer, Executor) -> Array[untyped]
          def initial_items(count, executor)
            raise ArgumentError, "Stream initial count must be non-negative" if count.negative?

            while positions_needing_initial_items(count).any?
              batch = pull(executor)
              if batch.empty?
                raise ImplementationError, "Stream source yielded an empty batch before satisfying initialCount"
              end
              ingest(batch)
            end

            Array.new(bound_cardinality) do |position|
              static_value = static_values[position]
              if !static_value.equal?(NO_STATIC_VALUE)
                static_value
              elsif (error = errors[position])
                error
              else
                buffers[position].shift(count)
              end
            end
          end

          #: -> Array[Integer]
          def pending_positions
            Array.new(bound_cardinality) { _1 }.select do |position|
              static_values[position].equal?(NO_STATIC_VALUE) &&
                errors[position].nil? &&
                (!buffers[position].empty? || !completed[position])
            end
          end

          #: (Executor) -> Batch
          def next_batch(executor)
            batch = buffered_batch
            return batch unless batch.empty?
            return batch if completed.all?

            ingest(pull(executor))
            buffered_batch
          end

          #: (Integer) -> void
          def close_position(position)
            completed[position] = true
            close_source(position)
          end

          #: -> void
          def close
            return if @closed

            @closed = true
            close_sources
          end

          private

          #: -> Integer
          def bound_cardinality
            @cardinality || raise(ImplementationError, "Stream session has not been bound to a field")
          end

          #: -> Array[Array[untyped]]
          def buffers
            @buffers #: as !nil
          end

          #: -> Array[bool]
          def completed
            @completed #: as !nil
          end

          #: -> Array[bool]
          def completion_reported
            @completion_reported #: as !nil
          end

          #: -> Array[StandardError?]
          def errors
            @errors #: as !nil
          end

          #: -> Array[untyped]
          def static_values
            @static_values #: as !nil
          end

          #: (Integer) -> Array[Integer]
          def positions_needing_initial_items(count)
            return EMPTY_ARRAY if count.zero?

            Array.new(bound_cardinality) { _1 }.select do |position|
              static_values[position].equal?(NO_STATIC_VALUE) &&
                errors[position].nil? &&
                !completed[position] &&
                buffers[position].length < count
            end
          end

          #: (Batch) -> void
          def ingest(batch)
            batch.items_by_position.each do |position, items|
              validate_position!(position)
              buffers[position].concat(items)
            end
            batch.errors_by_position.each do |position, error|
              validate_position!(position)
              errors[position] = error
              completed[position] = true
            end
            batch.completed_positions.each do |position|
              validate_position!(position)
              completed[position] = true
            end
          end

          #: -> Batch
          def buffered_batch
            items_by_position = {}
            completed_positions = []
            errors_by_position = {}

            bound_cardinality.times do |position|
              unless buffers[position].empty?
                items_by_position[position] = buffers[position].shift(buffers[position].length)
              end

              if (error = errors[position]) && !completion_reported[position]
                errors_by_position[position] = error
              end

              if completed[position] && !completion_reported[position] && buffers[position].empty?
                completed_positions << position
                completion_reported[position] = true
              end
            end

            Batch.new(
              items_by_position: items_by_position.freeze,
              completed_positions: completed_positions.freeze,
              errors_by_position: errors_by_position.freeze,
            )
          end

          #: (Integer) -> void
          def validate_position!(position)
            unless position.is_a?(Integer) && position >= 0 && position < bound_cardinality
              raise ImplementationError, "Stream produced invalid breadth position #{position.inspect}"
            end
          end

          #: (untyped) -> Advance
          def advance(source)
            value = source.next
            if value.nil?
              Advance.new(items: EMPTY_ARRAY, complete: false, error: nil)
            elsif value.is_a?(Chunk)
              Advance.new(items: value.items, complete: value.complete, error: nil)
            elsif value.is_a?(Array)
              Advance.new(items: value, complete: false, error: nil)
            elsif value.is_a?(StandardError)
              Advance.new(items: EMPTY_ARRAY, complete: true, error: value)
            else
              raise ImplementationError, "Stream sources must yield an Array or Stream::Chunk, got #{value.class}"
            end
          rescue StopIteration
            Advance.new(items: EMPTY_ARRAY, complete: true, error: nil)
          rescue StandardError => error
            Advance.new(items: EMPTY_ARRAY, complete: true, error: error)
          end

          def after_bind
          end

          #: (Executor) -> Batch
          def pull(_executor)
            raise NotImplementedError
          end

          #: (Integer) -> void
          def close_source(_position)
          end

          #: -> void
          def close_sources
          end
        end

        class Collective < Session
          #: (Enumerator, async_settings: LazyLoader::AsyncSettings) -> void
          def initialize(enumerator, async_settings:)
            unless enumerator.respond_to?(:next)
              raise ArgumentError, "Collective streams require an Enumerator-like source"
            end

            super(async_settings)
            @enumerator = enumerator.is_a?(Enumerator) ? EnumeratorCursor.new(enumerator) : enumerator
          end

          private

          #: (Executor) -> Batch
          def pull(executor)
            advance = executor.execute_stream_sources([@enumerator], async_settings) { advance(_1) }.first
            if advance.error
              positions = Array.new(bound_cardinality) { _1 }
              return Batch.new(
                items_by_position: EMPTY_OBJECT,
                completed_positions: positions.freeze,
                errors_by_position: positions.to_h { [_1, advance.error] }.freeze,
              )
            end

            if advance.complete
              positions = Array.new(bound_cardinality) { _1 }.freeze
              return Batch.new(items_by_position: EMPTY_OBJECT, completed_positions: positions, errors_by_position: EMPTY_OBJECT)
            end

            mapped = advance.items
            unless mapped.length == bound_cardinality
              raise ImplementationError, "Collective stream yielded #{mapped.length} breadth positions, expected #{bound_cardinality}"
            end

            items_by_position = {}
            completed_positions = []
            mapped.each_with_index do |value, position|
              next if value.nil?
              if completed[position]
                raise ImplementationError, "Collective stream yielded more items for completed breadth position #{position}"
              end

              chunk = value.is_a?(Chunk) ? value : Chunk.new(items: value)
              items_by_position[position] = chunk.items unless chunk.items.empty?
              completed_positions << position if chunk.complete
            end

            Batch.new(
              items_by_position: items_by_position.freeze,
              completed_positions: completed_positions.freeze,
              errors_by_position: EMPTY_OBJECT,
            )
          end

          def close_sources
            @enumerator.close if @enumerator.respond_to?(:close)
          end
        end

        class Positional < Session
          #: (Array[Enumerator?], async_settings: LazyLoader::AsyncSettings) -> void
          def initialize(enumerators, async_settings:)
            raise ArgumentError, "Positional streams require an Array of sources" unless enumerators.is_a?(Array)

            super(async_settings)
            @enumerators = enumerators.map do |source|
              source.is_a?(Enumerator) ? EnumeratorCursor.new(source) : source
            end
          end

          #: (Integer) -> Positional
          def bind(cardinality)
            if @enumerators.length != cardinality
              raise ImplementationError, "Positional stream returned #{@enumerators.length} sources, expected #{cardinality}"
            end

            super
          end

          private

          def after_bind
            @enumerators.each_with_index do |source, position|
              if source.nil? || source.is_a?(StandardError)
                static_values[position] = source
                completed[position] = true
              elsif !source.respond_to?(:next)
                raise ImplementationError, "Positional stream source #{position} must respond to #next"
              end
            end
          end

          #: (Executor) -> Batch
          def pull(executor)
            sources = @enumerators.each_with_index.filter_map do |source, position|
              [position, source] unless completed[position]
            end
            return Batch.new(items_by_position: EMPTY_OBJECT, completed_positions: EMPTY_ARRAY, errors_by_position: EMPTY_OBJECT) if sources.empty?

            advances = executor.execute_stream_sources(sources, async_settings) do |(_position, source)|
              advance(source)
            end

            items_by_position = {}
            completed_positions = []
            errors_by_position = {}
            sources.each_with_index do |(position, _source), index|
              result = advances[index]
              items_by_position[position] = result.items unless result.items.empty?
              completed_positions << position if result.complete
              errors_by_position[position] = result.error if result.error
            end

            Batch.new(
              items_by_position: items_by_position.freeze,
              completed_positions: completed_positions.freeze,
              errors_by_position: errors_by_position.freeze,
            )
          end

          def close_source(position)
            source = @enumerators[position]
            source.close if source.respond_to?(:close)
          end

          def close_sources
            @enumerators.each { _1.close if _1.respond_to?(:close) }
          end
        end

        class Eager < Session
          #: (Array[untyped]) -> void
          def initialize(values)
            super(LazyLoader::DEFAULT_ASYNC_SETTINGS)
            @values = values
          end

          #: (Integer) -> Eager
          def bind(cardinality)
            unless @values.length == cardinality
              raise ImplementationError, "Eager stream returned #{@values.length} values, expected #{cardinality}"
            end

            super
          end

          private

          def after_bind
            @values.each_with_index do |value, position|
              if value.is_a?(Array)
                buffers[position].concat(value)
              else
                static_values[position] = value
              end
              completed[position] = true
            end
          end

          def pull(_executor)
            Batch.new(items_by_position: EMPTY_OBJECT, completed_positions: EMPTY_ARRAY, errors_by_position: EMPTY_OBJECT)
          end
        end
      end
    end
  end
end
