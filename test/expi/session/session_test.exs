defmodule Expi.SessionTest do
  use ExUnit.Case, async: true

  alias Expi.Session
  alias Expi.Session.AgentSession
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

  test "create_session returns agent session and initializes model/thinking entries" do
    {:ok, result} =
      Session.create_session(%{model: test_model(), in_memory: true, thinking_level: :high})

    assert %AgentSession{} = result.session
    assert result.model_fallback_message == nil

    entries = Expi.Session.Manager.get_entries(AgentSession.session_manager(result.session))

    assert Enum.any?(entries, &(Map.get(&1, :type) == :model_change))
    assert Enum.any?(entries, &(Map.get(&1, :type) == :thinking_level_change))
  end

  test "create_session resolves model from provider and model_id" do
    {:ok, result} =
      Session.create_session(%{
        provider: "anthropic",
        model_id: "claude-sonnet-3-6",
        in_memory: true
      })

    assert %AgentSession{} = result.session
    assert result.model_fallback_message == nil
  end

  test "create_session returns error when no model is supplied" do
    assert {:error, :model_required} = Session.create_session(%{in_memory: true})
  end
end
