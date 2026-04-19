defmodule Expi.Session.AgentSessionTest do
  use ExUnit.Case, async: true

  alias Expi.Session.AgentSession
  alias Expi.Session.Manager
  alias Expi.Types.Model

  defp test_model do
    %Model{
      id: "claude-sonnet-3-6",
      name: "Claude Sonnet",
      api: "anthropic",
      provider: "anthropic",
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: ["text"],
      cost: %Expi.Types.Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 8_000,
      headers: %{},
      compat: %{}
    }
  end

  test "prompt appends and persists user messages without running conversation" do
    {:ok, agent} = Expi.Agent.create(test_model(), %{system_prompt: "test"})
    manager = Manager.in_memory("/tmp/expi")

    session = %AgentSession{agent: agent, session_manager: manager}

    {:ok, session} = AgentSession.prompt(session, "hello", %{run_conversation: false})

    assert length(AgentSession.messages(session)) == 1
    assert length(Manager.get_entries(AgentSession.session_manager(session))) >= 1
  end

  test "compact writes compaction entry" do
    {:ok, agent} = Expi.Agent.create(test_model(), %{system_prompt: "test"})
    manager = Manager.in_memory("/tmp/expi")
    session = %AgentSession{agent: agent, session_manager: manager}

    {:ok, session} = AgentSession.prompt(session, "one", %{run_conversation: false})
    {:ok, session} = AgentSession.prompt(session, "two", %{run_conversation: false})
    {:ok, session} = AgentSession.prompt(session, "three", %{run_conversation: false})
    {:ok, session} = AgentSession.prompt(session, "four", %{run_conversation: false})

    {:ok, session, _result} = AgentSession.compact(session)

    assert Enum.any?(Manager.get_entries(AgentSession.session_manager(session)), fn e ->
             Map.get(e, :type) == :compaction
           end)
  end
end
