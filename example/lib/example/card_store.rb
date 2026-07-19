# frozen_string_literal: true

require "set"
require "thread"

module Example
  class CardStore
    INITIAL_CARD_IDS = [
      "9a879b60-4381-447d-8a5a-8e0b6a1d49ca",
      "711d4d54-5520-4de8-9b93-79902ed8e562",
      "312a6058-de08-487d-95bd-b3c56807fdd6",
      "386ea9eb-abc1-4862-aa2d-8fb808d79490",
    ].freeze

    attr_reader :members

    def initialize
      @members = Set.new(INITIAL_CARD_IDS)
      @cache = {}
      @cache_mutex = Mutex.new
    end

    def add(card_id)
      card_id = card_id.to_s
      members.add(card_id)
      self
    end

    def remove(card_id)
      card_id = card_id.to_s
      members.delete(card_id)
      self
    end

    def card_ids
      members.to_a
    end

    def where(model:, ids:)
      @cache_mutex.synchronize do
        records = @cache[model.to_s] || {}.freeze
        ids.filter_map { |id| records[id.to_s] }
      end
    end

    def write(model:, records:)
      @cache_mutex.synchronize do
        model_cache = (@cache[model.to_s] ||= {})

        records.each do |record|
          model_cache[record.fetch("id").to_s] = record unless record.nil?
        end
      end

      records
    end
  end
end
