# frozen_string_literal: true

require "graphql/breadth"

require_relative "../../loaders/magic_cards"

module Example
  module Resolvers
    module Query
      class MagicCards < GraphQL::Breadth::FieldResolver
        STREAM_CHUNK_SIZE = 10

        def resolve(exec_field, context)
          store = exec_field.objects.first
          card_ids = store.card_ids
          return exec_field.resolve_all([]) if card_ids.empty?

          cached_records = cached_records_by_id(store, card_ids)

          exec_field.lazy(
            loader_class: Example::Loaders::MagicCards,
            keys: card_ids,
            eager_values: cached_records,
          ).then { exec_field.resolve_all(_1) }
        end

        def stream(exec_field, context, initial_count:)
          sources = exec_field.objects.map do |store|
            card_ids = store.card_ids
            loader = Example::Loaders::MagicCards.new

            Enumerator.new do |yielder|
              offset = 0
              while offset < card_ids.length
                chunk_size = if offset.zero? && initial_count.positive?
                  initial_count
                else
                  STREAM_CHUNK_SIZE
                end
                ids = card_ids.slice(offset, chunk_size)
                offset += ids.length
                records = load_cards(store, ids, context, loader)

                yielder << GraphQL::Breadth::Incremental::Stream.chunk(
                  records,
                  complete: offset == card_ids.length,
                )
              end
            end
          end

          loader_settings = Example::Loaders::MagicCards.async_settings
          GraphQL::Breadth::Incremental::Stream.positional(
            sources,
            async: true,
            limit: loader_settings.limit,
            resource: loader_settings.resource,
            timeout: loader_settings.timeout,
            throttle: loader_settings.throttle,
          )
        end

        private

        def load_cards(store, card_ids, context, loader)
          records_by_id = cached_records_by_id(store, card_ids)
          missing_ids = card_ids.reject { records_by_id.key?(_1.to_s) }
          unless missing_ids.empty?
            loader.perform_map(missing_ids, context).each do |record|
              records_by_id[record.fetch("id").to_s] = record
            end
          end

          card_ids.filter_map { records_by_id[_1.to_s] }
        end

        def cached_records_by_id(store, card_ids)
          store
            .where(model: "MagicCard", ids: card_ids)
            .each_with_object({}) { |record, records| records[record.fetch("id").to_s] = record }
        end
      end
    end
  end
end
