defmodule Expi.Agent.ToolResultWarningTest do
  use ExUnit.Case, async: true

  alias Expi.Agent.ToolResult
  alias Expi.Types.{TextContent, ToolResultMessage}

  test "validate_results accepts tool results with list content" do
    results = [
      %ToolResultMessage{
        tool_call_id: "call_1",
        tool_name: "alpha",
        content: [%TextContent{type: :text, text: "ok"}],
        details: %{execution_time_ms: 10},
        is_error: false,
        timestamp: 1
      }
    ]

    assert :ok = ToolResult.validate_results(results)
  end

  test "validate_results reports malformed content" do
    results = [
      %ToolResultMessage{
        tool_call_id: "call_1",
        tool_name: "alpha",
        content: "not-a-list",
        details: %{execution_time_ms: 10},
        is_error: false,
        timestamp: 1
      }
    ]

    assert {:error, issues} = ToolResult.validate_results(results)
    assert Enum.any?(issues, &(&1 =~ "content is not a list"))
  end

  test "aggregate_by_criteria groups execution times into expected buckets" do
    results = [
      tool_result("fast", 999),
      tool_result("medium", 1_000),
      tool_result("medium_2", 4_999),
      tool_result("slow", 5_000),
      tool_result("very_slow", 15_000)
    ]

    grouped = ToolResult.aggregate_by_criteria(results, group_by: :execution_time, include_details: true)

    assert Enum.map(grouped[:fast].results, & &1.tool_name) == ["fast"]
    assert Enum.map(grouped[:medium].results, & &1.tool_name) |> Enum.sort() == ["medium", "medium_2"]
    assert Enum.map(grouped[:slow].results, & &1.tool_name) == ["slow"]
    assert Enum.map(grouped[:very_slow].results, & &1.tool_name) == ["very_slow"]
  end

  defp tool_result(tool_name, execution_time_ms) do
    %ToolResultMessage{
      tool_call_id: "call_#{tool_name}",
      tool_name: tool_name,
      content: [%TextContent{type: :text, text: "ok"}],
      details: %{execution_time_ms: execution_time_ms},
      is_error: false,
      timestamp: execution_time_ms
    }
  end
end
