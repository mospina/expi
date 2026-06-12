defmodule Expi.Agent.MessageProcessorTest do
  use ExUnit.Case, async: true

  alias Expi.Agent.MessageProcessor
  alias Expi.Agent.Tool
  alias Expi.Agent.Types.AgentState
  alias Expi.Types.{Model, UserMessage}

  test "process_pipeline builds an llm context without tools" do
    state = base_state(messages: [user_message("hello")])

    assert {:ok, context} = MessageProcessor.process_pipeline(state)
    assert context.system_prompt == ""
    assert Enum.map(context.messages, & &1.content) == ["hello"]
    assert context.tools == nil
  end

  test "process_pipeline includes converted tools in the llm context" do
    {:ok, tool} =
      Tool.text_tool("read", "Read a file", %{type: :object, properties: %{}}, fn _, _, _, _ ->
        {:ok, "ok"}
      end)

    state = base_state(messages: [user_message("hello")], tools: [tool])

    assert {:ok, context} = MessageProcessor.process_pipeline(state)
    assert [%{name: "read"}] = Enum.map(context.tools, & &1.function)
  end

  defp base_state(opts) do
    %AgentState{
      system_prompt: Keyword.get(opts, :system_prompt, ""),
      model: demo_model(),
      thinking_level: :off,
      tools: Keyword.get(opts, :tools, []),
      messages: Keyword.get(opts, :messages, []),
      is_streaming: false,
      stream_message: nil,
      pending_tool_calls: MapSet.new(),
      steering_queue: [],
      follow_up_queue: [],
      error: nil,
      created_at: System.system_time(:millisecond),
      max_context_length: nil,
      temperature: nil,
      streaming: true,
      loop_outcome: nil
    }
  end

  defp demo_model do
    %Model{
      id: "claude-sonnet-3-6",
      name: "Claude Sonnet",
      api: "anthropic",
      provider: "anthropic",
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: ["text"],
      cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 8_000,
      headers: %{},
      compat: %{}
    }
  end

  defp user_message(content) do
    %UserMessage{role: :user, content: content, timestamp: System.system_time(:millisecond)}
  end
end
