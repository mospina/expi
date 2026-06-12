defmodule Expi.Agent.TurnWarningTest do
  use ExUnit.Case, async: true

  alias Expi.Agent.{State, Turn}
  alias Expi.AI

  test "execute_turn extracts tool calls from streamed assistant responses" do
    {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")
    agent_state = State.new(model)

    stream_fn = fn _model, _context ->
      {:ok,
       [
         %{type: :start, partial: %{api: model.api, provider: model.provider, model: model.id}},
         %{
           type: :toolcall_start,
           content_index: 0,
           tool_call: %{id: "call_1", name: "search", arguments: %{query: "hello"}}
         },
         %{type: :toolcall_end, content_index: 0, tool_call: nil},
         %{type: :done, reason: :stop, message: %{usage: nil}}
       ]}
    end

    loop_state = %{
      agent_state: agent_state,
      options: %{transform_context: nil, convert_to_llm: nil, stream_fn: stream_fn},
      current_turn: 1
    }

    assert {:ok, final_state} = Turn.execute_turn(loop_state, nil)
    assert length(final_state.messages) == 1
    assert State.has_pending_tools?(final_state)
    assert MapSet.member?(State.get_pending_tool_calls(final_state), "call_1")

    assistant_message = hd(final_state.messages)
    assert Enum.any?(assistant_message.content, &(&1.type == :tool_call))
  end
end
