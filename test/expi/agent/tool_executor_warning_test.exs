defmodule Expi.Agent.ToolExecutorWarningTest do
  use ExUnit.Case, async: true

  alias Expi.Agent.ToolExecutor
  alias Expi.Types.{TextContent, ToolResultMessage}

  test "aggregate_tool_results computes totals and averages without empty-list regressions" do
    results = [
      %ToolResultMessage{
        tool_call_id: "call_1",
        tool_name: "alpha",
        content: [%TextContent{type: :text, text: "ok"}],
        details: %{execution_time_ms: 10},
        is_error: false,
        timestamp: 1
      },
      %ToolResultMessage{
        tool_call_id: "call_2",
        tool_name: "beta",
        content: [%TextContent{type: :text, text: "failed"}],
        details: %{execution_time_ms: 30},
        is_error: true,
        timestamp: 2
      }
    ]

    summary = ToolExecutor.aggregate_tool_results(results, %{source: :test})

    assert summary.total_tools == 2
    assert summary.successful == 1
    assert summary.failed == 1
    assert summary.success_rate == 0.5
    assert summary.total_execution_time == 40
    assert summary.average_execution_time == 20.0
    assert summary.results == results
    assert summary.metadata == %{source: :test}
  end
end
