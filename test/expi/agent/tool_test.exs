defmodule Expi.Agent.ToolTest do
  use ExUnit.Case, async: true

  alias Expi.Agent.Tool
  alias Expi.Agent.Types.AgentToolResult
  alias Expi.Types.TextContent
  alias Expi.Types.Tool, as: LlmTool

  describe "new/5" do
    test "creates a valid agent tool" do
      assert {:ok, tool} =
               Expi.Agent.Tool.new(
                 "calculator",
                 "Performs calculations",
                 %{type: :object, properties: %{expression: %{type: :string}}},
                 "Calculator",
                 fn _id, _params, _abort, _update ->
                   {:ok, AgentToolResult.text("4")}
                 end
               )

      assert tool.function.name == "calculator"
      assert tool.label == "Calculator"
      assert is_function(tool.execute, 4)
    end

    test "rejects invalid name" do
      assert {:error, :invalid_name} =
               Expi.Agent.Tool.new(
                 "",
                 "desc",
                 %{type: :object},
                 "Label",
                 fn _, _, _, _ -> {:ok, AgentToolResult.text("ok")} end
               )
    end
  end

  describe "execute/4" do
    test "returns successful tool result" do
      {:ok, tool} =
        Expi.Agent.Tool.new(
          "echo",
          "Echoes text",
          %{type: :object, properties: %{text: %{type: :string}}},
          "Echo",
          fn _id, params, _abort, _update ->
            {:ok,
             %AgentToolResult{
               content: [%TextContent{type: :text, text: params["text"]}],
               details: %{echoed: true}
             }}
          end
        )

      assert {:ok, %AgentToolResult{} = result} =
               Tool.execute(tool, "call_1", %{"text" => "hello"})

      assert [%TextContent{text: "hello"}] = result.content
    end

    test "captures execution error" do
      {:ok, tool} =
        Expi.Agent.Tool.new(
          "boom",
          "Raises",
          %{type: :object, properties: %{}},
          "Boom",
          fn _id, _params, _abort, _update ->
            raise "boom"
          end
        )

      assert {:error, {:execution_error, msg}} = Tool.execute(tool, "call_2", %{})
      assert String.contains?(msg, "boom")
    end
  end

  describe "to_llm_tool/1 and to_llm_tools/1" do
    test "converts tools to Expi.Types.Tool" do
      {:ok, agent_tool} =
        Expi.Agent.Tool.new(
          "search",
          "Search docs",
          %{type: :object, properties: %{query: %{type: :string}}},
          "Search",
          fn _id, _params, _abort, _update -> {:ok, AgentToolResult.text("done")} end
        )

      llm_tool = Tool.to_llm_tool(agent_tool)
      assert %LlmTool{type: :function, function: %{name: "search"}} = llm_tool

      list = Tool.to_llm_tools([agent_tool])
      assert [%LlmTool{}] = list
    end
  end

  describe "find_by_name/2" do
    test "finds existing tool" do
      {:ok, tool} =
        Expi.Agent.Tool.new(
          "search",
          "Search docs",
          %{type: :object, properties: %{}},
          "Search",
          fn _id, _params, _abort, _update -> {:ok, AgentToolResult.text("done")} end
        )

      assert {:ok, found} = Tool.find_by_name([tool], "search")
      assert found.function.name == "search"
    end

    test "returns not found for missing tool" do
      assert {:error, :tool_not_found} = Tool.find_by_name([], "missing")
    end
  end

  describe "validate_all/1 and names/1" do
    test "validates list and extracts names" do
      {:ok, tool1} =
        Expi.Agent.Tool.new(
          "first",
          "First tool",
          %{type: :object, properties: %{}},
          "First",
          fn _id, _params, _abort, _update -> {:ok, AgentToolResult.text("1")} end
        )

      {:ok, tool2} =
        Expi.Agent.Tool.new(
          "second",
          "Second tool",
          %{type: :object, properties: %{}},
          "Second",
          fn _id, _params, _abort, _update -> {:ok, AgentToolResult.text("2")} end
        )

      assert :ok = Tool.validate_all([tool1, tool2])
      assert ["first", "second"] = Tool.names([tool1, tool2])
    end
  end

  describe "text_tool/4" do
    test "wraps plain text responses" do
      assert {:ok, tool} =
               Tool.text_tool(
                 "plain",
                 "Plain text tool",
                 %{type: :object, properties: %{}},
                 fn _id, _params, _abort, _update -> {:ok, "hello"} end
               )

      assert {:ok, %AgentToolResult{content: [%TextContent{text: "hello"}]}} =
               Tool.execute(tool, "call_3", %{})
    end
  end
end
