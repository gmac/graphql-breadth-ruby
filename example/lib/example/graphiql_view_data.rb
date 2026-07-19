# frozen_string_literal: true

module Example
  module GraphiQLViewData
    DEFAULT_MODE = "query"
    MODES = {
      "query" => {
        "path" => "/query",
        "label" => "Query/Mutation",
        "transport" => "json",
        "defaultQuery" => <<~GRAPHQL,
          query MagicCards {
            magicCards {
              id
              name
              imageUri
              set {
                code
                name
              }
            }
          }

          mutation AddAnotherCard {
            addAnotherCard {
              id
              name
              imageUri
            }
          }
        GRAPHQL
        "variables" => {},
      },
      "defer" => {
        "path" => "/defer",
        "label" => "Defer",
        "transport" => "sse",
        "defaultQuery" => <<~GRAPHQL,
          query DeferredCardRulings {
            magicCards {
              id
              name
              ... @defer(label: "rulings") {
                rulings {
                  date
                  comment
                }
              }
            }
          }
        GRAPHQL
        "variables" => {},
        "inspector" => {
          "title" => "SSE Stream",
          "empty" => "Run the operation to see SSE payloads",
        },
      },
      "subscriptions" => {
        "path" => "/subscriptions",
        "label" => "Subscriptions",
        "transport" => "sse",
        "defaultQuery" => <<~GRAPHQL,
          subscription CardAdded {
            cardAdded {
              id
              name
            }
          }
        GRAPHQL
        "variables" => {},
        "inspector" => {
          "title" => "Card Events",
          "empty" => "Start the subscription, then add a card",
        },
        "trigger" => {
          "label" => "Add Card",
          "graphqlParams" => {
            "query" => <<~GRAPHQL,
              mutation AddAnotherCard {
                addAnotherCard {
                  id
                  name
                }
              }
            GRAPHQL
            "operationName" => "AddAnotherCard",
          },
        },
      },
    }.freeze

    NAV_ITEMS = MODES.map do |id, config|
      {
        "id" => id,
        "path" => config.fetch("path"),
        "label" => config.fetch("label"),
      }
    end.freeze

    MODE_IDS_BY_PATH = MODES.to_h { |id, config| [config.fetch("path"), id] }.freeze

    module_function

    def default_path
      MODES.fetch(DEFAULT_MODE).fetch("path")
    end

    def for_path(path)
      mode_id = MODE_IDS_BY_PATH[path]
      return unless mode_id

      {
        current_mode: mode_id,
        mode_config: MODES.fetch(mode_id),
        nav_items: NAV_ITEMS,
      }
    end
  end
end
