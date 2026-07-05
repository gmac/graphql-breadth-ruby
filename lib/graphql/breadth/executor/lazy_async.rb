# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    class Executor
      # @requires_ancestor: Executor
      module LazyAsync
        class ExecutorContext
          #: Executor
          attr_reader :executor

          #: ::Async::Barrier
          attr_reader :barrier

          #: ::Async::Queue
          attr_reader :completed_batches

          #: Set[LazyLoader[untyped]]
          attr_reader :active_loaders

          #: Set[LazyElement]
          attr_reader :waiting_elements

          #: Exception?
          attr_accessor :exception

          #: Hash[Symbol, ::Async::Semaphore]
          attr_reader :semaphores_by_resource

          #: (Executor, ::Async::Task) -> void
          def initialize(executor, task)
            @executor = executor
            @barrier = ::Async::Barrier.new(parent: task)
            @completed_batches = ::Async::Queue.new
            @active_loaders = Set.new.compare_by_identity
            @waiting_elements = Set.new.compare_by_identity
            @semaphores_by_resource = {}
          end

          #: (Symbol, Integer) -> ::Async::Semaphore
          def semaphore_for(resource, limit)
            semaphore = @semaphores_by_resource[resource]
            if semaphore
              if semaphore.limit != limit
                Kernel.raise ArgumentError, "Conflicting lazy async limits for resource #{resource.inspect}: #{semaphore.limit} and #{limit}"
              end

              return semaphore
            end

            @semaphores_by_resource[resource] = ::Async::Semaphore.new(limit, parent: @barrier)
          end
        end

        class LoaderContext
          #: (LazyLoader[untyped], ExecutorContext, ::Async::Task) -> void
          def initialize(loader, async_context, parent_task)
            @loader = loader
            @async_context = async_context
            @barrier = ::Async::Barrier.new(parent: parent_task)
            @futures = []
            @parent_semaphore = nil
          end

          #: (?resource: Symbol?, ?limit: Integer?, ?timeout: Numeric?) ?{ -> untyped } -> Future
          def async(resource: nil, limit: nil, timeout: nil, &block)
            Kernel.raise ArgumentError, "LazyLoader#async requires a block" unless block

            settings = @loader.async_settings
            resource = settings.resource if resource.nil?
            limit = settings.limit if limit.nil?
            timeout = settings.timeout if timeout.nil?

            Kernel.raise ArgumentError, "Lazy async limit must be positive" unless limit.nil? || limit > 0
            Kernel.raise ArgumentError, "Lazy async timeout must be positive" unless timeout.nil? || timeout > 0

            # child fan-out shares the parent resource budget, so release the parent slot before waiting on child slots.
            release_parent_permit if @parent_semaphore && @loader.async_settings.resource == resource

            parent = if limit
              semaphore_resource = resource #: as !nil
              @async_context.semaphore_for(semaphore_resource, limit)
            else
              @barrier
            end

            task = parent.async(parent: @barrier) do |async_task|
              begin
                if timeout
                  async_task.with_timeout(timeout, ::Async::TimeoutError, &block)
                else
                  block.call
                end
              rescue StandardError => e
                @async_context.executor.handle_or_reraise(e)
              end
            end

            @futures << Future.new(task)
            @futures.last
          end

          #: [T, U] (Enumerable[T], ?resource: Symbol?, ?limit: Integer?, ?timeout: Numeric?) ?{ (T) -> U } -> Array[U]
          def async_map(collection, resource: nil, limit: nil, timeout: nil, &block)
            Kernel.raise ArgumentError, "LazyLoader#async_map requires a block" unless block

            completed = false
            futures = collection.map do |item|
              async(resource: resource, limit: limit, timeout: timeout) { block.call(item) }
            end

            results = futures.map(&:wait)
            completed = true
            results
          ensure
            stop unless completed
          end

          #: () { -> untyped } -> untyped
          def run(&block)
            acquire_parent_permit
            value = yield
            wait
            value
          ensure
            stop
            release_parent_permit
          end

          private

          #: -> void
          def wait
            @futures.each do |future|
              future.wait unless future.observed?
            end

            @barrier.wait
          end

          #: -> void
          def stop
            @barrier.stop unless @barrier.empty?
          end

          #: -> void
          def acquire_parent_permit
            settings = @loader.async_settings
            return unless settings.limit

            @parent_semaphore = @async_context.semaphore_for(settings.resource, settings.limit)
            @parent_semaphore.acquire
          end

          #: -> void
          def release_parent_permit
            semaphore = @parent_semaphore
            return unless semaphore

            @parent_semaphore = nil
            semaphore.release
          end
        end

        class Future
          #: (::Async::Task) -> void
          def initialize(task)
            @task = task
            @observed = false
            @resolved = false
            @value = nil
          end

          #: -> bool
          def observed?
            @observed
          end

          #: -> untyped
          def wait
            @observed = true
            return @value if @resolved

            @value = @task.wait
            @resolved = true
            @value
          end
        end

        private

        #: (Array[LazyLoader::Batch], Array[LazyLoader::Batch]) -> void
        def execute_async_lazy_batches(sync_batches, async_batches)
          Kernel.Sync do |task|
            executor = self #: as Executor
            async_context = ExecutorContext.new(executor, task)

            begin
              async_batches.each { schedule_async_lazy_batch(async_context, _1) }
              sync_batches.each { execute_sync_lazy_batch(async_context, _1) }

              until async_context.active_loaders.empty?
                batch = async_context.completed_batches.dequeue
                async_context.active_loaders.delete(batch.loader)

                if (ex = async_context.exception)
                  raise ex
                end

                resume_lazy_elements_and_drain_requeued(async_context, batch.elements)
                retry_waiting_lazy_elements(async_context)
              end

              # terminal sweep...
              retry_waiting_lazy_elements(async_context)
            ensure
              async_context.barrier.stop unless async_context.active_loaders.empty?
            end
          end
        end

        #: (ExecutorContext, LazyLoader::Batch) -> void
        def schedule_async_lazy_batch(async_context, batch)
          async_context.active_loaders.add(batch.loader)

          async_context.barrier.async do |async_task|
            settings = batch.loader.async_settings
            loader_context = LoaderContext.new(batch.loader, async_context, async_task)

            begin
              begin
                if settings.timeout
                  async_task.with_timeout(settings.timeout) do
                    loader_context.run { execute_lazy_batch(batch, async_context: loader_context) }
                  end
                else
                  loader_context.run { execute_lazy_batch(batch, async_context: loader_context) }
                end
              rescue StandardError => e
                apply_lazy_error(batch, handle_or_reraise(e))
              end
            rescue Exception => ex
              # don't let async task failures strand the scheduler
              # mark the batch complete, then re-raise in the executor path
              async_context.exception ||= ex
            ensure
              async_context.completed_batches << batch
            end
          end
        end

        #: (ExecutorContext, LazyLoader::Batch) -> void
        def execute_sync_lazy_batch(async_context, batch)
          execute_lazy_batch(batch)
          resume_lazy_elements_and_drain_requeued(async_context, batch.elements)
        end

        #: (ExecutorContext, Array[LazyElement]) -> void
        def resume_lazy_elements_and_drain_requeued(async_context, elements)
          queue_start = @lazy_queue.length
          resume_lazy_elements(elements)

          return unless @lazy_queue.length > queue_start

          requeued_elements = @lazy_queue.slice!(queue_start, @lazy_queue.length - queue_start) #: as !nil
          requeued_element = requeued_elements.first #: as !nil
          scheduled_elements = schedule_pending_lazy_batches(async_context, requeued_element)

          requeued_elements.each do |element|
            next if scheduled_elements.include?(element)

            async_context.waiting_elements.add(element)
          end
        end

        #: (ExecutorContext, LazyElement) -> Set[LazyElement]
        def schedule_pending_lazy_batches(async_context, requeued_element)
          pending_loader_count = 0
          sync_pending_batches = nil #: Array[LazyLoader::Batch]?
          async_pending_batches = nil #: Array[LazyLoader::Batch]?
          scheduled_elements = nil #: Set[LazyElement]?

          (@loader_cache || EMPTY_OBJECT).each_value do |loader|
            next if loader.promised.empty? || async_context.active_loaders.include?(loader)

            pending_loader_count += 1
            batch = loader.to_batch
            if batch.aborted?
              loader.reset!
            else
              (scheduled_elements ||= Set.new.compare_by_identity).merge(batch.elements)

              if batch.loader.async_settings.enabled?
                (async_pending_batches ||= []) << batch
              else
                (sync_pending_batches ||= []) << batch
              end
            end
          end

          if pending_loader_count.zero?
            if async_context.active_loaders.empty?
              raise ImplementationError, "Lazy #{requeued_element} produced a promise without a loader"
            end

            return EMPTY_SET
          end

          return EMPTY_SET if scheduled_elements.nil?

          async_pending_batches&.each { schedule_async_lazy_batch(async_context, _1) }
          sync_pending_batches&.each { execute_sync_lazy_batch(async_context, _1) }

          scheduled_elements
        end

        #: (ExecutorContext) -> void
        def retry_waiting_lazy_elements(async_context)
          return if async_context.waiting_elements.empty?

          elements = async_context.waiting_elements.to_a
          async_context.waiting_elements.clear

          resume_lazy_elements_and_drain_requeued(async_context, elements)
        end
      end
    end
  end
end
