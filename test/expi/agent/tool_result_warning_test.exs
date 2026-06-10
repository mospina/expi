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
end
