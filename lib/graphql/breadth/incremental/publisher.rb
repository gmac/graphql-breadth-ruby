# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    module Incremental
      class Publisher
        def initialize
          @ids = {}.compare_by_identity
          @next_id = 0
        end

        #: (Array[Delivery]) -> Array[graphql_result]
        def pending(deliveries)
          deliveries.map do |delivery|
            result = {
              "id" => id_for(delivery),
              "path" => delivery.path,
            }
            result["label"] = delivery.label if delivery.label
            result
          end
        end

        #: (Array[DeferredDelivery], error_path, graphql_result, ?errors: Array[error_hash]) -> graphql_result
        def deferred(deliveries, path, data, errors: EMPTY_ARRAY)
          delivery = best_delivery_for(deliveries, path)
          result = {
            "data" => data,
            "id" => id_for(delivery),
          }

          sub_path = path.drop(delivery.path.length)
          result["subPath"] = sub_path unless sub_path.empty?
          result["errors"] = errors unless errors.empty?
          result
        end

        #: (StreamDelivery, Array[untyped], ?errors: Array[error_hash]) -> graphql_result
        def stream(delivery, items, errors: EMPTY_ARRAY)
          result = {
            "items" => items,
            "id" => id_for(delivery),
          }
          result["errors"] = errors unless errors.empty?
          result
        end

        #: (Delivery, ?errors: Array[error_hash]) -> graphql_result
        def completed(delivery, errors: EMPTY_ARRAY)
          result = { "id" => id_for(delivery) }
          result["errors"] = errors unless errors.empty?
          @ids.delete(delivery)
          result
        end

        private

        #: (DeferredDelivery) -> String
        def id_for(delivery)
          @ids[delivery] ||= begin
            id = @next_id.to_s
            @next_id += 1
            id
          end
        end

        #: (Array[DeferredDelivery], error_path) -> DeferredDelivery
        def best_delivery_for(deliveries, path)
          deliveries.max_by { |delivery| delivery.path_prefix_of?(path) ? delivery.path.length : -1 } #: as !nil
        end
      end
    end
  end
end
