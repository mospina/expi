defmodule Expi.SessionBuiltinToolsTest do
  use ExUnit.Case

  alias Expi.Agent
  alias Expi.Session
  alias Expi.Session.AgentSession
  alias Expi.Types.{Cost, Model}

  test "default tool exposure includes read,bash,edit,write" do
    {:ok, %{session: session}} = Session.create_session(%{model: demo_model(), in_memory: true})

    names = session |> AgentSession.state() |> Agent.get_tools() |> Enum.map(& &1.function.name)

    assert Enum.take(names, 4) == ["read", "bash", "edit", "write"]
  end

  test "tool_mode :none disables built-ins but keeps caller tools" do
    {:ok, custom_tool} =
      Expi.Agent.Tool.text_tool("custom", "custom", %{type: :object}, fn _, _, _, _ -> {:ok, "ok"} end)

    {:ok, %{session: session}} =
      Session.create_session(%{model: demo_model(), in_memory: true, tool_mode: :none, tools: [custom_tool]})

    names = session |> AgentSession.state() |> Agent.get_tools() |> Enum.map(& &1.function.name)
    assert names == ["custom"]
  end

  test "tool_mode {:only, names} selects subset deterministically" do
    {:ok, %{session: session}} =
      Session.create_session(%{model: demo_model(), in_memory: true, tool_mode: {:only, ["read", "ls"]}})

    names = session |> AgentSession.state() |> Agent.get_tools() |> Enum.map(& &1.function.name)
    assert names == ["read", "ls"]
  end

  test "caller tool overrides built-in by name" do
    {:ok, override} =
      Expi.Agent.Tool.text_tool("read", "override", %{type: :object}, fn _, _, _, _ -> {:ok, "override"} end)

    {:ok, %{session: session}} =
      Session.create_session(%{model: demo_model(), in_memory: true, tools: [override]})

    names = session |> AgentSession.state() |> Agent.get_tools() |> Enum.map(& &1.function.name)
    assert List.last(names) == "read"
  end

  test "diagnostics include unknown built-in names" do
    {:ok, %{session: session}} =
      Session.create_session(%{
        model: demo_model(),
        in_memory: true,
        tool_mode: {:only, ["read", "missing_tool"]}
      })

    diagnostics = AgentSession.get_diagnostics(session)

    assert Enum.any?(diagnostics, fn d -> d.source == "builtin_tools" and d.message =~ "unknown built-in tool" end)
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
      cost: %Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 8_000,
      headers: %{},
      compat: %{}
    }
  end
end
