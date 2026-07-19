# frozen_string_literal: true

require "test_helper"

class GraphQL::Breadth::Executor::IncrementalTest < Minitest::Test
  class BatchTrackingLoader < GraphQL::Breadth::LazyLoader
    class << self
      attr_accessor :perform_keys
    end

    self.perform_keys = []

    def map?
      true
    end

    def perform_map(keys, _ctx)
      self.class.perform_keys << keys.dup
      keys
    end
  end

  class LazyHashResolver < GraphQL::Breadth::FieldResolver
    def initialize(key)
      @key = key
    end

    def resolve(exec_field, _ctx)
      exec_field.lazy(loader_class: BatchTrackingLoader, keys: exec_field.objects.map { _1[@key] })
    end
  end

  class RejectFirstForkObjectAuthorization < GraphQL::Breadth::Authorization
    def authorize_objects_in_scope?(exec_scope, _context)
      exec_scope.is_a?(GraphQL::Breadth::Incremental::ExecutionScope)
    end

    def unauthorized_object_indices(exec_scope, _context)
      return {} unless exec_scope.is_a?(GraphQL::Breadth::Incremental::ExecutionScope)

      { 0 => GraphQL::Breadth::ExecutionError.new("Stream item hidden") }
    end
  end

  SOURCE = {
    "products" => {
      "nodes" => [{
        "id" => "gid://shopify/Product/1",
        "title" => "Banana",
        "must" => "yes",
        "variants" => {
          "nodes" => [{
            "id" => "gid://shopify/Variant/1",
            "title" => "Small Banana",
          }],
        },
      }, {
        "id" => "gid://shopify/Product/2",
        "title" => "Apple",
        "must" => "yes",
        "variants" => {
          "nodes" => [{
            "id" => "gid://shopify/Variant/2",
            "title" => "Small Apple",
          }],
        },
      }],
    },
  }.freeze

  def test_incremental_result_returns_normal_result_without_defer
    result = build_executor(%|{
      products(first: 2) {
        nodes {
          id
          title
        }
      }
    }|).incremental_result

    expected = {
      "data" => {
        "products" => {
          "nodes" => [
            { "id" => "gid://shopify/Product/1", "title" => "Banana" },
            { "id" => "gid://shopify/Product/2", "title" => "Apple" },
          ],
        },
      },
    }

    assert_instance_of GraphQL::Breadth::Incremental::Result, result
    refute result.incremental?
    assert_equal expected, result.initial_result
    assert_equal [], result.subsequent_results.to_a
    assert_equal expected, result.to_h
  end

  def test_incremental_result_raises_after_result
    executor = build_executor(%|{
      products(first: 2) {
        nodes { id }
      }
    }|)

    executor.result
    error = assert_raises(GraphQL::Breadth::ImplementationError) do
      executor.incremental_result
    end

    assert_equal "Cannot call incremental_result after result", error.message
  end

  def test_result_raises_after_incremental_result
    executor = build_executor(%|{
      products(first: 2) {
        nodes { id }
      }
    }|)

    executor.incremental_result
    error = assert_raises(GraphQL::Breadth::ImplementationError) do
      executor.result
    end

    assert_equal "Cannot call result after incremental_result", error.message
  end

  def test_incremental_result_returns_same_result_on_repeat_call
    executor = build_executor(%|{
      products(first: 2) {
        nodes { id }
      }
    }|)

    result = executor.incremental_result
    assert_same result, executor.incremental_result
  end

  def test_incremental_result_does_not_defer_when_if_is_false
    result = build_executor(%|{
      products(first: 1) {
        nodes {
          id
          ... @defer(if: false) { title }
        }
      }
    }|).incremental_result

    expected = {
      "data" => {
        "products" => {
          "nodes" => [
            { "id" => "gid://shopify/Product/1", "title" => "Banana" },
            { "id" => "gid://shopify/Product/2", "title" => "Apple" },
          ],
        },
      },
    }

    assert_instance_of GraphQL::Breadth::Incremental::Result, result
    refute result.incremental?
    assert_equal expected, result.initial_result
    assert_equal [], result.subsequent_results.to_a
    assert_equal(
      expected,
      result.to_h,
    )
  end

  def test_incremental_result_defers_when_if_is_null
    result = build_executor(%|query($shouldDefer: Boolean) {
      products(first: 1) {
        nodes {
          id
          ... @defer(if: $shouldDefer) { title }
        }
      }
    }|, source: one_product_source).incremental_result

    assert_equal(
      {
        "data" => {
          "products" => {
            "nodes" => [{ "id" => "gid://shopify/Product/1" }],
          },
        },
        "pending" => [{ "id" => "0", "path" => ["products", "nodes", 0] }],
        "hasNext" => true,
      },
      result.initial_result,
    )
    assert_equal(
      [{
        "incremental" => [{ "data" => { "title" => "Banana" }, "id" => "0" }],
        "completed" => [{ "id" => "0" }],
        "hasNext" => false,
      }],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_defers_fragment_for_each_list_object
    result = build_executor(%|{
      products(first: 2) {
        nodes {
          id
          ... @defer { title }
        }
      }
    }|).incremental_result

    assert_instance_of GraphQL::Breadth::Incremental::Result, result
    assert_equal(
      {
        "data" => {
          "products" => {
            "nodes" => [
              { "id" => "gid://shopify/Product/1" },
              { "id" => "gid://shopify/Product/2" },
            ],
          },
        },
        "pending" => [
          { "id" => "0", "path" => ["products", "nodes", 0] },
          { "id" => "1", "path" => ["products", "nodes", 1] },
        ],
        "hasNext" => true,
      },
      result.initial_result,
    )

    assert_equal(
      [{
        "incremental" => [
          { "data" => { "title" => "Banana" }, "id" => "0" },
          { "data" => { "title" => "Apple" }, "id" => "1" },
        ],
        "completed" => [
          { "id" => "0" },
          { "id" => "1" },
        ],
        "hasNext" => false,
      }],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_includes_defer_label
    result = build_executor(%|{
      products(first: 1) {
        nodes {
          id
          ... @defer(label: "ProductTitle") { title }
        }
      }
    }|, source: one_product_source).incremental_result

    assert_equal(
      [{ "id" => "0", "path" => ["products", "nodes", 0], "label" => "ProductTitle" }],
      result.initial_result.fetch("pending"),
    )
  end

  def test_incremental_result_treats_null_label_as_no_label
    result = build_executor(%|{
      products(first: 1) {
        nodes {
          id
          ... @defer(label: null) { title }
        }
      }
    }|, source: one_product_source).incremental_result

    assert_equal(
      [{ "id" => "0", "path" => ["products", "nodes", 0] }],
      result.initial_result.fetch("pending"),
    )
  end

  def test_incremental_result_deduplicates_fragment_also_selected_without_defer
    [
      %|query ProductTitleQuery {
        products(first: 1) {
          nodes {
            ...Title @defer(label: "DeferredTitle")
            ...Title
          }
        }
      }

      fragment Title on Product {
        title
      }|,
      %|query ProductTitleQuery {
        products(first: 1) {
          nodes {
            ...Title
            ...Title @defer(label: "DeferredTitle")
          }
        }
      }

      fragment Title on Product {
        title
      }|,
    ].each do |document|
      result = build_executor(document, source: one_product_source).incremental_result

      expected = {
        "data" => {
          "products" => {
            "nodes" => [{ "title" => "Banana" }],
          },
        },
      }

      refute result.incremental?
      assert_equal expected, result.initial_result
      assert_equal [], result.subsequent_results.to_a
    end
  end

  def test_incremental_result_defers_inline_fragment
    result = build_executor(%|{
      products(first: 1) {
        nodes {
          id
          ... on Product @defer(label: "InlineTitle") {
            title
          }
        }
      }
    }|, source: one_product_source).incremental_result

    assert_equal(
      {
        "data" => {
          "products" => {
            "nodes" => [{ "id" => "gid://shopify/Product/1" }],
          },
        },
        "pending" => [{ "id" => "0", "path" => ["products", "nodes", 0], "label" => "InlineTitle" }],
        "hasNext" => true,
      },
      result.initial_result,
    )
    assert_equal(
      [{
        "incremental" => [{ "data" => { "title" => "Banana" }, "id" => "0" }],
        "completed" => [{ "id" => "0" }],
        "hasNext" => false,
      }],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_does_not_emit_empty_defer_fragments
    result = build_executor(%|{
      products(first: 1) {
        nodes {
          ... @defer {
            title @skip(if: true)
          }
        }
      }
    }|, source: one_product_source).incremental_result

    expected = {
      "data" => {
        "products" => {
          "nodes" => [{}],
        },
      },
    }

    refute result.incremental?
    assert_equal expected, result.initial_result
    assert_equal [], result.subsequent_results.to_a
  end

  def test_incremental_result_emits_children_of_empty_defer_fragments
    result = build_executor(%|{
      products(first: 1) {
        nodes {
          ... @defer {
            ... @defer {
              title
            }
          }
        }
      }
    }|, source: one_product_source).incremental_result

    assert_equal(
      {
        "data" => {
          "products" => {
            "nodes" => [{}],
          },
        },
        "pending" => [{ "id" => "0", "path" => ["products", "nodes", 0] }],
        "hasNext" => true,
      },
      result.initial_result,
    )
    assert_equal(
      [{
        "incremental" => [{ "data" => { "title" => "Banana" }, "id" => "0" }],
        "completed" => [{ "id" => "0" }],
        "hasNext" => false,
      }],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_deduplicates_nested_defers_on_the_same_object
    result = build_executor(%|query ProductTitleQuery {
      products(first: 1) {
        nodes {
          ... @defer {
            ...ProductTitle
            ... @defer {
              ...ProductTitle
              ... @defer {
                ...ProductTitle
              }
            }
          }
        }
      }
    }

    fragment ProductTitle on Product {
      id
      title
    }|, source: one_product_source).incremental_result

    assert_equal(
      {
        "data" => {
          "products" => {
            "nodes" => [{}],
          },
        },
        "pending" => [{ "id" => "0", "path" => ["products", "nodes", 0] }],
        "hasNext" => true,
      },
      result.initial_result,
    )
    assert_equal(
      [{
        "incremental" => [{
          "data" => {
            "id" => "gid://shopify/Product/1",
            "title" => "Banana",
          },
          "id" => "0",
        }],
        "completed" => [{ "id" => "0" }],
        "hasNext" => false,
      }],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_separately_emits_nested_defers_on_the_same_object
    result = build_executor(%|{
      products(first: 1) {
        nodes {
          id
          ... @defer(label: "Outer") {
            title
            ... @defer(label: "Inner") {
              must
            }
          }
        }
      }
    }|, source: one_product_source).incremental_result

    assert_equal(
      {
        "data" => {
          "products" => {
            "nodes" => [{ "id" => "gid://shopify/Product/1" }],
          },
        },
        "pending" => [
          { "id" => "0", "path" => ["products", "nodes", 0], "label" => "Outer" },
          { "id" => "1", "path" => ["products", "nodes", 0], "label" => "Inner" },
        ],
        "hasNext" => true,
      },
      result.initial_result,
    )
    assert_equal(
      [
        {
          "incremental" => [{ "data" => { "title" => "Banana" }, "id" => "0" }],
          "completed" => [{ "id" => "0" }],
          "hasNext" => true,
        },
        {
          "incremental" => [{ "data" => { "must" => "yes" }, "id" => "1" }],
          "completed" => [{ "id" => "1" }],
          "hasNext" => false,
        },
      ],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_defers_top_level_fragment
    result = build_executor(%|{
      ... @defer(label: "Top") {
        products(first: 1) {
          nodes { title }
        }
      }
    }|).incremental_result

    assert_equal(
      {
        "data" => {},
        "pending" => [{ "id" => "0", "path" => [], "label" => "Top" }],
        "hasNext" => true,
      },
      result.initial_result,
    )
    assert_equal(
      [{
        "incremental" => [{
          "data" => {
            "products" => {
              "nodes" => [
                { "title" => "Banana" },
                { "title" => "Apple" },
              ],
            },
          },
          "id" => "0",
        }],
        "completed" => [{ "id" => "0" }],
        "hasNext" => false,
      }],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_formats_errors_in_top_level_deferred_fragment
    source = Marshal.load(Marshal.dump(one_product_source))
    source["products"]["nodes"][0]["title"] = GraphQL::ExecutionError.new("No title")

    result = build_executor(%|{
      ... @defer(label: "Top") {
        products(first: 1) {
          nodes { title }
        }
      }
    }|, source: source).incremental_result

    assert_equal(
      {
        "data" => {},
        "pending" => [{ "id" => "0", "path" => [], "label" => "Top" }],
        "hasNext" => true,
      },
      result.initial_result,
    )
    assert_equal(
      [{
        "incremental" => [{
          "data" => {
            "products" => {
              "nodes" => [{ "title" => nil }],
            },
          },
          "id" => "0",
          "errors" => [{
            "message" => "No title",
            "locations" => [{ "line" => 4, "column" => 19 }],
            "path" => ["products", "nodes", 0, "title"],
          }],
        }],
        "completed" => [{ "id" => "0" }],
        "hasNext" => false,
      }],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_separately_emits_fragments_with_different_labels
    result = build_executor(%|{
      products(first: 1) {
        nodes {
          ... @defer(label: "DeferredId") { id }
          ... @defer(label: "DeferredTitle") { title }
        }
      }
    }|, source: one_product_source).incremental_result

    assert_equal(
      {
        "data" => {
          "products" => {
            "nodes" => [{}],
          },
        },
        "pending" => [
          { "id" => "0", "path" => ["products", "nodes", 0], "label" => "DeferredId" },
          { "id" => "1", "path" => ["products", "nodes", 0], "label" => "DeferredTitle" },
        ],
        "hasNext" => true,
      },
      result.initial_result,
    )
    assert_equal(
      [
        {
          "incremental" => [{ "data" => { "id" => "gid://shopify/Product/1" }, "id" => "0" }],
          "completed" => [{ "id" => "0" }],
          "hasNext" => true,
        },
        {
          "incremental" => [{ "data" => { "title" => "Banana" }, "id" => "1" }],
          "completed" => [{ "id" => "1" }],
          "hasNext" => false,
        },
      ],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_uses_sub_path_for_nested_payloads
    result = build_executor(%|{
      ... @defer(label: "DeferredId") {
        products(first: 1) {
          nodes { id }
        }
      }
      ... @defer(label: "DeferredTitle") {
        products(first: 1) {
          nodes { title }
        }
      }
    }|, source: one_product_source).incremental_result

    assert_equal(
      {
        "data" => {},
        "pending" => [
          { "id" => "0", "path" => [], "label" => "DeferredId" },
          { "id" => "1", "path" => [], "label" => "DeferredTitle" },
        ],
        "hasNext" => true,
      },
      result.initial_result,
    )
    assert_equal(
      [
        {
          "incremental" => [{
            "data" => {
              "products" => {
                "nodes" => [{}],
              },
            },
            "id" => "0",
          }],
          "hasNext" => true,
        },
        {
          "incremental" => [{
            "data" => { "id" => "gid://shopify/Product/1" },
            "id" => "0",
            "subPath" => ["products", "nodes", 0],
          }],
          "completed" => [{ "id" => "0" }],
          "hasNext" => true,
        },
        {
          "incremental" => [{
            "data" => { "title" => "Banana" },
            "id" => "1",
            "subPath" => ["products", "nodes", 0],
          }],
          "completed" => [{ "id" => "1" }],
          "hasNext" => false,
        },
      ],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_formats_nullable_errors_in_deferred_payload
    source = Marshal.load(Marshal.dump(SOURCE))
    source["products"]["nodes"][0]["title"] = GraphQL::ExecutionError.new("Oops!")

    result = build_executor(%|{
      products(first: 1) {
        nodes {
          id
          ... @defer { title }
        }
      }
    }|, source: source).incremental_result

    assert_equal(
      [{
        "incremental" => [
          {
            "data" => { "title" => nil },
            "id" => "0",
            "errors" => [{
              "message" => "Oops!",
              "locations" => [{ "line" => 5, "column" => 24 }],
              "path" => ["products", "nodes", 0, "title"],
            }],
          },
          { "data" => { "title" => "Apple" }, "id" => "1" },
        ],
        "completed" => [
          { "id" => "0" },
          { "id" => "1" },
        ],
        "hasNext" => false,
      }],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_supports_nested_defer
    result = build_executor(%|{
      products(first: 1) {
        nodes {
          id
          ... @defer(label: "Outer") {
            title
            variants(first: 1) {
              nodes {
                id
                ... @defer(label: "Inner") { title }
              }
            }
          }
        }
      }
    }|, source: one_product_source).incremental_result

    assert_equal(
      {
        "data" => {
          "products" => {
            "nodes" => [{ "id" => "gid://shopify/Product/1" }],
          },
        },
        "pending" => [{ "id" => "0", "path" => ["products", "nodes", 0], "label" => "Outer" }],
        "hasNext" => true,
      },
      result.initial_result,
    )
    assert_equal(
      [
        {
          "pending" => [{
            "id" => "1",
            "path" => ["products", "nodes", 0, "variants", "nodes", 0],
            "label" => "Inner",
          }],
          "incremental" => [{
            "data" => {
              "title" => "Banana",
              "variants" => {
                "nodes" => [{ "id" => "gid://shopify/Variant/1" }],
              },
            },
            "id" => "0",
          }],
          "completed" => [{ "id" => "0" }],
          "hasNext" => true,
        },
        {
          "incremental" => [{ "data" => { "title" => "Small Banana" }, "id" => "1" }],
          "completed" => [{ "id" => "1" }],
          "hasNext" => false,
        },
      ],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_cancels_nested_defer_when_parent_deferred_fragment_fails
    source = Marshal.load(Marshal.dump(SOURCE))
    source["products"]["nodes"] = [source["products"]["nodes"].first]
    source["products"]["nodes"][0]["must"] = nil

    result = build_executor(%|{
      products(first: 1) {
        nodes {
          id
          ... @defer(label: "Outer") {
            must
            variants(first: 1) {
              nodes {
                id
                ... @defer(label: "Inner") { title }
              }
            }
          }
        }
      }
    }|, source: source).incremental_result

    assert_equal(
      {
        "data" => {
          "products" => {
            "nodes" => [{ "id" => "gid://shopify/Product/1" }],
          },
        },
        "pending" => [{ "id" => "0", "path" => ["products", "nodes", 0], "label" => "Outer" }],
        "hasNext" => true,
      },
      result.initial_result,
    )
    assert_equal(
      [{
        "completed" => [{
          "id" => "0",
          "errors" => [{
            "message" => "Cannot return null for non-nullable field Product.must",
            "locations" => [{ "line" => 6, "column" => 13 }],
            "path" => ["products", "nodes", 0, "must"],
            "extensions" => { "code" => "INVALID_NULL" },
          }],
        }],
        "hasNext" => false,
      }],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_completes_deferred_group_with_non_null_errors
    source = Marshal.load(Marshal.dump(SOURCE))
    source["products"]["nodes"][0]["must"] = nil
    source["products"]["nodes"] = [source["products"]["nodes"][0]]

    result = build_executor(%|{
      products(first: 1) {
        nodes {
          id
          ... @defer { must }
        }
      }
    }|, source: source).incremental_result

    assert_equal(
      [{
        "completed" => [{
          "id" => "0",
          "errors" => [{
            "message" => "Cannot return null for non-nullable field Product.must",
            "locations" => [{ "line" => 5, "column" => 24 }],
            "path" => ["products", "nodes", 0, "must"],
            "extensions" => { "code" => "INVALID_NULL" },
          }],
        }],
        "hasNext" => false,
      }],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_cancels_deferred_payload_for_null_bubbled_parent
    source = Marshal.load(Marshal.dump(SOURCE))
    source["products"]["nodes"] = [source["products"]["nodes"].first]
    source["products"]["nodes"][0]["must"] = nil

    result = build_executor(%|{
      products(first: 1) {
        nodes {
          must
          ... @defer { title }
        }
      }
    }|, source: source).incremental_result

    assert_equal(
      { "products" => nil },
      result.initial_result.fetch("data"),
    )
    refute result.initial_result.key?("pending")
    refute result.initial_result.key?("hasNext")
    assert_equal(
      [{
        "message" => "Cannot return null for non-nullable field Product.must",
        "locations" => [{ "line" => 4, "column" => 11 }],
        "path" => ["products", "nodes", 0, "must"],
        "extensions" => { "code" => "INVALID_NULL" },
      }],
      result.initial_result.fetch("errors"),
    )
    assert_equal [], result.subsequent_results.to_a
  end

  def test_incremental_result_filters_deferred_payload_for_null_bubbled_list_element
    # `nodes: [Node]!` has NULLABLE elements. Element 0's non-null `must` returns nil, so the
    # element null-bubbles to null in the initial result while the list and its siblings survive
    # (no scope abort). A deferred fragment is attached to that now-dead element: it must NOT be
    # announced as pending or delivered as incremental — there is no live object to patch into.
    source = {
      "nodes" => [
        { "__typename__" => "Product", "id" => "1", "must" => nil, "title" => "Banana" },
        { "__typename__" => "Product", "id" => "2", "must" => "yes", "title" => "Apple" },
      ],
    }

    result = build_executor(%|{
      nodes(ids: ["1", "2"]) {
        ... on Product {
          id
          must
          ... @defer { title }
        }
      }
    }|, source: source).incremental_result

    assert_instance_of GraphQL::Breadth::Incremental::Result, result

    initial = result.initial_result
    assert_equal(
      { "nodes" => [nil, { "id" => "2", "must" => "yes" }] },
      initial.fetch("data"),
    )
    # only the surviving element (index 1) is announced; the null-bubbled element 0 is filtered out.
    assert_equal(
      [{ "id" => "0", "path" => ["nodes", 1] }],
      initial.fetch("pending"),
    )
    assert_equal(true, initial.fetch("hasNext"))
    assert_equal(["nodes", 0, "must"], initial.fetch("errors").first.fetch("path"))

    # the dead element delivers nothing; the surviving element delivers and completes normally.
    assert_equal(
      [{
        "incremental" => [{ "data" => { "title" => "Apple" }, "id" => "0" }],
        "completed" => [{ "id" => "0" }],
        "hasNext" => false,
      }],
      result.subsequent_results.to_a,
    )
  end

  def test_ready_deferred_executions_batch_lazy_work
    source = Marshal.load(Marshal.dump(SOURCE))
    source["products"]["nodes"][0]["maybe"] = "Yellow"
    source["products"]["nodes"][1]["maybe"] = "Red"

    resolvers = BREADTH_RESOLVERS.merge(
      "Product" => BREADTH_RESOLVERS.fetch("Product").merge(
        "title" => LazyHashResolver.new("title"),
        "maybe" => LazyHashResolver.new("maybe"),
      ),
    )

    BatchTrackingLoader.perform_keys = []

    result = build_executor(%|{
      products(first: 2) {
        nodes {
          id
          ... @defer(label: "Title") { title }
          ... @defer(label: "Maybe") { maybe }
        }
      }
    }|, source:, resolvers:).incremental_result

    result.subsequent_results.to_a

    assert_equal(
      [["Banana", "Apple"], ["Yellow", "Red"]],
      BatchTrackingLoader.perform_keys,
    )
  end

  def test_incremental_result_streams_list_field
    result = build_executor(%|{
      products(first: 2) {
        nodes @stream(initialCount: 1) {
          id
          title
        }
      }
    }|).incremental_result

    assert_equal(
      {
        "data" => {
          "products" => {
            "nodes" => [{ "id" => "gid://shopify/Product/1", "title" => "Banana" }],
          },
        },
        "pending" => [{ "id" => "0", "path" => ["products", "nodes"] }],
        "hasNext" => true,
      },
      result.initial_result,
    )
    assert_equal(
      [{
        "incremental" => [{
          "items" => [{ "id" => "gid://shopify/Product/2", "title" => "Apple" }],
          "id" => "0",
        }],
        "completed" => [{ "id" => "0" }],
        "hasNext" => false,
      }],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_streams_with_default_initial_count
    result = build_executor(%|{
      products(first: 2) {
        nodes @stream { id }
      }
    }|).incremental_result

    assert_equal(
      {
        "data" => { "products" => { "nodes" => [] } },
        "pending" => [{ "id" => "0", "path" => ["products", "nodes"] }],
        "hasNext" => true,
      },
      result.initial_result,
    )
    assert_equal(
      [{
        "incremental" => [{
          "items" => [
            { "id" => "gid://shopify/Product/1" },
            { "id" => "gid://shopify/Product/2" },
          ],
          "id" => "0",
        }],
        "completed" => [{ "id" => "0" }],
        "hasNext" => false,
      }],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_includes_stream_label
    result = build_executor(%|{
      products(first: 2) {
        nodes @stream(initialCount: 1, label: "ProductNodes") { id }
      }
    }|).incremental_result

    assert_equal(
      [{ "id" => "0", "path" => ["products", "nodes"], "label" => "ProductNodes" }],
      result.initial_result.fetch("pending"),
    )
  end

  def test_incremental_result_does_not_stream_when_if_is_false
    result = build_executor(%|{
      products(first: 2) {
        nodes @stream(initialCount: 0, if: false) { id }
      }
    }|).incremental_result

    expected = {
      "data" => {
        "products" => {
          "nodes" => [
            { "id" => "gid://shopify/Product/1" },
            { "id" => "gid://shopify/Product/2" },
          ],
        },
      },
    }
    refute result.incremental?
    assert_equal expected, result.initial_result
  end

  def test_incremental_result_does_not_announce_stream_without_a_tail
    result = build_executor(%|{
      products(first: 2) {
        nodes @stream(initialCount: 2) { id }
      }
    }|).incremental_result

    refute result.incremental?
    assert_equal 2, result.initial_result.dig("data", "products", "nodes").length
  end

  def test_incremental_result_streams_alias_with_variable_arguments
    result = build_executor(
      %|query($enabled: Boolean, $count: Int) {
        products(first: 2) {
          cards: nodes @stream(if: $enabled, initialCount: $count) { id }
        }
      }|,
      variables: { "enabled" => true, "count" => 1 },
    ).incremental_result

    assert_equal [{ "id" => "0", "path" => ["products", "cards"] }], result.initial_result.fetch("pending")
    assert_equal(
      [{ "id" => "gid://shopify/Product/2" }],
      result.subsequent_results.to_a.fetch(0).fetch("incremental").fetch(0).fetch("items"),
    )
  end

  def test_stream_execution_batches_lazy_work_for_tail_items
    resolvers = BREADTH_RESOLVERS.merge(
      "Product" => BREADTH_RESOLVERS.fetch("Product").merge(
        "title" => LazyHashResolver.new("title"),
      ),
    )
    BatchTrackingLoader.perform_keys = []

    result = build_executor(%|{
      products(first: 2) {
        nodes @stream { title }
      }
    }|, resolvers:).incremental_result
    result.subsequent_results.to_a

    assert_equal [["Banana", "Apple"]], BatchTrackingLoader.perform_keys
  end

  def test_stream_execution_batches_tail_work_across_parent_lists
    source = Marshal.load(Marshal.dump(SOURCE))
    source["products"]["nodes"][0]["variants"]["nodes"] = [
      { "id" => "variant-1", "title" => "Small Banana" },
      { "id" => "variant-2", "title" => "Large Banana" },
    ]
    source["products"]["nodes"][1]["variants"]["nodes"] = [
      { "id" => "variant-3", "title" => "Small Apple" },
      { "id" => "variant-4", "title" => "Large Apple" },
    ]
    resolvers = BREADTH_RESOLVERS.merge(
      "Variant" => BREADTH_RESOLVERS.fetch("Variant").merge(
        "title" => LazyHashResolver.new("title"),
      ),
    )
    BatchTrackingLoader.perform_keys = []

    result = build_executor(%|{
      products(first: 2) {
        nodes {
          variants(first: 2) {
            nodes @stream(initialCount: 1) { title }
          }
        }
      }
    }|, source:, resolvers:).incremental_result

    assert_equal(
      [
        { "id" => "0", "path" => ["products", "nodes", 0, "variants", "nodes"] },
        { "id" => "1", "path" => ["products", "nodes", 1, "variants", "nodes"] },
      ],
      result.initial_result.fetch("pending"),
    )
    payload = result.subsequent_results.to_a.fetch(0)
    assert_equal(
      [
        { "items" => [{ "title" => "Large Banana" }], "id" => "0" },
        { "items" => [{ "title" => "Large Apple" }], "id" => "1" },
      ],
      payload.fetch("incremental"),
    )
    assert_equal(
      [["Small Banana", "Small Apple"], ["Large Banana", "Large Apple"]],
      BatchTrackingLoader.perform_keys,
    )
  end

  def test_defer_inside_stream_registers_tail_deferred_work
    result = build_executor(%|{
      products(first: 2) {
        nodes @stream(initialCount: 1, label: "Nodes") {
          id
          ... @defer(label: "Title") { title }
        }
      }
    }|).incremental_result

    payloads = result.subsequent_results.to_a
    stream_payload = payloads.find { _1.fetch("incremental", []).any? { |entry| entry.key?("items") } }
    tail_defer = payloads.find do |payload|
      payload.fetch("incremental", []).any? { |entry| entry["data"] == { "title" => "Apple" } }
    end

    assert_equal [{ "id" => "gid://shopify/Product/2" }], stream_payload.fetch("incremental").first.fetch("items")
    assert_equal({ "title" => "Apple" }, tail_defer.fetch("incremental").first.fetch("data"))
    assert_equal false, payloads.last.fetch("hasNext")
  end

  def test_stream_inside_defer_runs_after_deferred_parent
    result = build_executor(%|{
      products(first: 2) {
        ... @defer(label: "Nodes") {
          nodes @stream(initialCount: 1, label: "Tail") { id }
        }
      }
    }|).incremental_result

    payloads = result.subsequent_results.to_a
    outer = payloads.fetch(0)
    tail = payloads.fetch(1)

    assert_equal [{ "id" => "gid://shopify/Product/1" }], outer.fetch("incremental").first.dig("data", "nodes")
    assert_equal [{ "id" => "gid://shopify/Product/2" }], tail.fetch("incremental").first.fetch("items")
    assert_equal false, tail.fetch("hasNext")
  end

  def test_result_ignores_stream_and_returns_the_complete_list
    executor = build_executor(%|{
      products(first: 2) {
        nodes @stream(initialCount: 0) { id }
      }
    }|)
    result = executor.result

    assert_equal 2, result.dig("data", "products", "nodes").length
    refute result.key?("pending")
    refute result.key?("hasNext")
    assert_nil executor.incremental
  end

  def test_incremental_result_streams_leaf_list_items
    source = Marshal.load(Marshal.dump(SOURCE))
    source["products"]["nodes"] = [source["products"]["nodes"].first]
    source["products"]["nodes"][0]["tags"] = ["fruit", "yellow", "ripe"]

    result = build_executor(%|{
      products(first: 1) {
        nodes {
          tags @stream(initialCount: 1)
        }
      }
    }|, source:).incremental_result

    assert_equal ["fruit"], result.initial_result.dig("data", "products", "nodes", 0, "tags")
    assert_equal(
      [{
        "incremental" => [{ "items" => ["yellow", "ripe"], "id" => "0" }],
        "completed" => [{ "id" => "0" }],
        "hasNext" => false,
      }],
      result.subsequent_results.to_a,
    )
  end

  def test_incremental_result_formats_nullable_stream_item_errors
    source = Marshal.load(Marshal.dump(SOURCE))
    source["products"]["nodes"] = [source["products"]["nodes"].first]
    source["products"]["nodes"][0]["tags"] = ["fruit", GraphQL::ExecutionError.new("No tag")]

    result = build_executor(%|{
      products(first: 1) {
        nodes {
          tags @stream(initialCount: 1)
        }
      }
    }|, source:).incremental_result
    incremental = result.subsequent_results.to_a.fetch(0).fetch("incremental").fetch(0)

    assert_equal [nil], incremental.fetch("items")
    assert_equal "No tag", incremental.fetch("errors").first.fetch("message")
    assert_equal ["products", "nodes", 0, "tags", 1], incremental.fetch("errors").first.fetch("path")
  end

  def test_incremental_result_streams_abstract_list_items
    source = {
      "nodes" => [
        { "__typename__" => "Product", "id" => "1", "title" => "Banana" },
        { "__typename__" => "Product", "id" => "2", "title" => "Apple" },
      ],
    }

    result = build_executor(%|{
      nodes(ids: ["1", "2"]) @stream(initialCount: 1) {
        id
        ... on Product { title }
      }
    }|, source:).incremental_result

    assert_equal(
      [{ "id" => "1", "title" => "Banana" }],
      result.initial_result.dig("data", "nodes"),
    )
    assert_equal(
      [{ "id" => "2", "title" => "Apple" }],
      result.subsequent_results.to_a.fetch(0).fetch("incremental").fetch(0).fetch("items"),
    )
  end

  def test_incremental_result_terminates_stream_for_non_null_item_error
    source = Marshal.load(Marshal.dump(SOURCE))
    source["products"]["nodes"] = [source["products"]["nodes"].first]
    source["products"]["nodes"][0]["requiredTags"] = ["fruit", nil]

    result = build_executor(%|{
      products(first: 1) {
        nodes {
          requiredTags @stream(initialCount: 1)
        }
      }
    }|, source:).incremental_result
    payload = result.subsequent_results.to_a.fetch(0)

    refute payload.key?("incremental")
    assert_equal ["products", "nodes", 0, "requiredTags", 1], payload.dig("completed", 0, "errors", 0, "path")
    assert_equal false, payload.fetch("hasNext")
  end

  def test_stream_fork_preserves_paths_when_authorization_removes_an_item
    source = {
      "nodes" => [
        { "__typename__" => "Product", "id" => "1" },
        { "__typename__" => "Product", "id" => "2" },
      ],
    }
    result = build_executor(
      %|{ nodes(ids: ["1", "2"]) @stream { id } }|,
      source:,
      authorization: RejectFirstForkObjectAuthorization,
    ).incremental_result
    incremental = result.subsequent_results.to_a.fetch(0).fetch("incremental").fetch(0)

    assert_equal [nil, { "id" => "2" }], incremental.fetch("items")
    assert_equal ["nodes", 0], incremental.fetch("errors").first.fetch("path")
  end

  private

  def build_executor(
    document,
    source: SOURCE,
    resolvers: BREADTH_RESOLVERS,
    authorization: GraphQL::Breadth::Authorization,
    variables: {}
  )
    GraphQL::Breadth::Executor.new(
      SCHEMA,
      GraphQL.parse(document),
      resolvers: resolvers,
      root_object: source,
      authorization:,
      variables:,
    )
  end

  def one_product_source
    {
      "products" => {
        "nodes" => [SOURCE.fetch("products").fetch("nodes").first],
      },
    }
  end
end
