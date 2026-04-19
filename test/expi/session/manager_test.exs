defmodule Expi.Session.ManagerTest do
  use ExUnit.Case, async: true

  alias Expi.Session.Manager
  alias Expi.Types.{AssistantMessage, UserMessage}

  test "in-memory manager appends messages and builds context" do
    manager = Manager.in_memory("/tmp/expi")

    user = %UserMessage{
      role: :user,
      content: "hello",
      timestamp: System.system_time(:millisecond)
    }

    assistant = %AssistantMessage{
      role: :assistant,
      content: [],
      api: "anthropic",
      provider: "anthropic",
      model: "claude-sonnet-3-6",
      timestamp: System.system_time(:millisecond)
    }

    {manager, _} = Manager.append_model_change(manager, "anthropic", "claude-sonnet-3-6")
    {manager, _} = Manager.append_thinking_level_change(manager, :medium)
    {manager, _} = Manager.append_message(manager, user)
    {manager, _} = Manager.append_message(manager, assistant)

    context = Manager.build_session_context(manager)

    assert context.thinking_level == "medium"
    assert context.model == %{provider: "anthropic", model_id: "claude-sonnet-3-6"}
    assert length(context.messages) == 2
  end

  test "branch resets leaf and supports branch summaries" do
    manager = Manager.in_memory("/tmp/expi")

    {manager, first_id} =
      Manager.append_message(manager, %UserMessage{role: :user, content: "first", timestamp: 1})

    {manager, _second_id} =
      Manager.append_message(manager, %UserMessage{role: :user, content: "second", timestamp: 2})

    manager = Manager.branch(manager, first_id)
    {manager, _} = Manager.branch_with_summary(manager, first_id, "summary")

    context = Manager.build_session_context(manager)

    assert Enum.any?(context.messages, fn msg ->
             msg.role == :user and is_binary(msg.content) and
               String.contains?(msg.content, "Branch Summary")
           end)
  end
end
