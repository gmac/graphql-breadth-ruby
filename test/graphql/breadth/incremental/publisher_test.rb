# frozen_string_literal: true

require "test_helper"

class GraphQL::Breadth::Incremental::PublisherTest < Minitest::Test
  DeferredDelivery = GraphQL::Breadth::Incremental::DeferredDelivery
  Publisher = GraphQL::Breadth::Incremental::Publisher

  def test_pending_assigns_stable_ids_and_includes_label
    publisher = Publisher.new
    delivery = DeferredDelivery.new(["hero"], "HeroFields")

    expected = [{ "id" => "0", "path" => ["hero"], "label" => "HeroFields" }]

    assert_equal expected, publisher.pending([delivery])
    assert_equal expected, publisher.pending([delivery])
  end

  def test_deferred_payload_uses_deepest_matching_delivery
    publisher = Publisher.new
    parent = DeferredDelivery.new(["hero"], "HeroFields")
    child = DeferredDelivery.new(["hero", "friends", 0], "FriendFields", parent: parent)

    publisher.pending([parent, child])

    assert_equal(
      {
        "data" => { "name" => "Han" },
        "id" => "1",
        "subPath" => ["profile"],
      },
      publisher.deferred([parent, child], ["hero", "friends", 0, "profile"], { "name" => "Han" }),
    )
    assert_equal(
      {
        "data" => { "appearsIn" => ["NEWHOPE"] },
        "id" => "0",
        "subPath" => ["appearsIn"],
      },
      publisher.deferred([parent, child], ["hero", "appearsIn"], { "appearsIn" => ["NEWHOPE"] }),
    )
  end

  def test_completed_includes_errors_and_allocates_new_ids_after_completion
    publisher = Publisher.new
    delivery = DeferredDelivery.new(["hero"])

    assert_equal [{ "id" => "0", "path" => ["hero"] }], publisher.pending([delivery])
    assert_equal(
      {
        "id" => "0",
        "errors" => [{ "message" => "bad" }],
      },
      publisher.completed(delivery, errors: [{ "message" => "bad" }]),
    )
    assert_equal [{ "id" => "1", "path" => ["hero"] }], publisher.pending([delivery])
  end
end
