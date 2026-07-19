# frozen_string_literal: true

require "test_helper"

class GraphQL::Breadth::Incremental::CoordinatorTest < Minitest::Test
  DeferredWork = GraphQL::Breadth::Incremental::DeferredWork
  ExecutionScope = GraphQL::Breadth::Executor::ExecutionScope

  def test_deferred_work_is_not_ready_when_base_scope_aborted
    executor = GraphQL::Breadth::Executor.new(
      SCHEMA,
      GraphQL.parse("{ noResolver }"),
      resolvers: BREADTH_RESOLVERS,
      root_object: {},
    )
    base_scope = ExecutionScope.new(
      executor: executor,
      parent_type: SCHEMA.query,
      selections: [],
      objects: [{}].freeze,
      results: [{}].freeze,
    )
    base_scope.executed = true

    deferred_work = DeferredWork.new(
      base_scope: base_scope,
      field_selections: {},
      defer_usages: Set.new,
    )

    assert deferred_work.ready?
    base_scope.abort!
    refute deferred_work.ready?
  end
end
