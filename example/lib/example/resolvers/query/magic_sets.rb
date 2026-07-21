# frozen_string_literal: true

require "graphql/breadth"

require_relative "../../loaders/magic_cards"
require_relative "../../loaders/magic_card_sets"

module Example
  module Resolvers
    module Query
      class MagicSets < GraphQL::Breadth::FieldResolver
        def resolve(exec_field, context)
          store = context.fetch(:card_store)
          card_ids_by_position = exec_field.objects.map(&:card_ids)

          handle_resolved(load_cards(exec_field, store, card_ids_by_position.flatten.uniq)) do |cards|
            positional_set_ids = set_ids_by_position(card_ids_by_position, cards)
            load_sets(exec_field, store, positional_set_ids)
          end
        end

        def stream(exec_field, context, initial_count:)
          store = context.fetch(:card_store)
          card_ids_by_position = exec_field.objects.map(&:card_ids)

          handle_resolved(load_cards(exec_field, store, card_ids_by_position.flatten.uniq)) do |cards|
            build_stream(store, context, set_ids_by_position(card_ids_by_position, cards))
          end
        end

        private

        def load_cards(exec_field, store, card_ids)
          return [] if card_ids.empty?

          exec_field.lazy(
            loader_class: Example::Loaders::MagicCards,
            keys: card_ids,
            eager_values: cached_records_by_id(store, "MagicCard", card_ids),
          )
        end

        def load_sets(exec_field, store, set_ids_by_position)
          set_ids = set_ids_by_position.flatten.uniq
          return exec_field.resolve_all([]) if set_ids.empty?

          exec_field.lazy(
            loader_class: Example::Loaders::MagicCardSets,
            keys: set_ids,
            eager_values: cached_records_by_id(store, "MagicSet", set_ids),
          ).then do |sets|
            sets_by_id = sets.each_with_object({}) { |set, records| records[set.fetch("id").to_s] = set }
            set_ids_by_position.map { |position_ids| position_ids.filter_map { sets_by_id[_1.to_s] } }
          end
        end

        def build_stream(store, context, set_ids_by_position)
          sources = set_ids_by_position.map do |set_ids|
            loader = Example::Loaders::MagicCardSets.new

            Enumerator.new do |yielder|
              cached_sets = cached_records_by_id(store, "MagicSet", set_ids)
              set_ids.each_with_index do |set_id, index|
                set = cached_sets[set_id.to_s] || loader.perform_one(set_id, context)
                yielder << GraphQL::Breadth::Incremental::Stream.chunk(
                  [set],
                  complete: index == set_ids.length - 1,
                )
              end
            end
          end

          settings = Example::Loaders::MagicCardSets.async_settings
          GraphQL::Breadth::Incremental::Stream.positional(
            sources,
            async: true,
            limit: settings.limit,
            resource: settings.resource,
            timeout: settings.timeout,
            throttle: settings.throttle,
          )
        end

        def set_ids_by_position(card_ids_by_position, cards)
          cards_by_id = cards.each_with_object({}) { |card, records| records[card.fetch("id").to_s] = card }
          card_ids_by_position.map do |card_ids|
            card_ids.filter_map { |card_id| cards_by_id[card_id.to_s]&.fetch("setId") }.uniq
          end
        end

        def cached_records_by_id(store, model, ids)
          store
            .where(model:, ids:)
            .each_with_object({}) { |record, records| records[record.fetch("id").to_s] = record }
        end
      end
    end
  end
end
