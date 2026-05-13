#!/usr/bin/env elixir

# Lightweight WebSocket server demo for Expi Session runtime
#
# Starts a tiny Cowboy-based WS server and keeps one session per socket.
#
# Usage:
#   cd expi
#   elixir demos/session_ws_server_demo.exs
#
# Health check:
#   curl -s http://localhost:8080/health
#
# Test with wscat:
#   npx wscat -c ws://localhost:8080/ws
#   > {"type":"create_session","provider":"anthropic","model_id":"claude-sonnet-3-6","in_memory":true}
#   > {"type":"prompt","text":"Draft release notes","run_conversation":true}
#   > {"type":"messages"}
#   > {"type":"compact","instructions":"Keep only key actions"}
#   > {"type":"stats"}

Mix.install([
  {:expi, path: "."},
  {:jason, "~> 1.4"},
  {:cowboy, "~> 2.12"}
])

defmodule SessionWsServerDemo.Extension do
  @behaviour Expi.Session.Extension

  def register(_ctx) do
    %{
      commands: [
        %{
          name: "echo",
          description: "Echo command text into session",
          handler: fn args, session, _ctx ->
            Expi.Session.AgentSession.prompt(session, "[echo] " <> args, %{run_conversation: false, expand_resources: false})
          end
        }
      ]
    }
  end
end

defmodule SessionWsServerDemo.Handler do
  @behaviour :cowboy_websocket

  alias Expi.Agent
  alias Expi.Session
  alias Expi.Session.AgentSession
  alias Expi.Session.Manager

  @impl true
  def init(req, _state) do
    {:cowboy_websocket, req, %{session: nil}}
  end

  @impl true
  def websocket_handle({:text, payload}, state) do
    response = handle_message(payload, state)

    case response do
      {:ok, reply, new_state} ->
        {:reply, {:text, Jason.encode!(reply)}, new_state}

      {:error, error_reply, new_state} ->
        {:reply, {:text, Jason.encode!(error_reply)}, new_state}
    end
  end

  def websocket_handle(_frame, state), do: {:ok, state}

  @impl true
  def websocket_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _req, _state), do: :ok

  defp handle_message(payload, state) do
    with {:ok, data} <- Jason.decode(payload) do
      route(data, state)
    else
      _ -> {:error, %{ok: false, error: "invalid_json"}, state}
    end
  end

  defp route(%{"type" => "create_session"} = data, state) do
    provider = Map.get(data, "provider", "anthropic")
    model_id = Map.get(data, "model_id", "claude-sonnet-3-6")
    in_memory = Map.get(data, "in_memory", true)

    case Session.create_session(%{
           provider: provider,
           model_id: model_id,
           in_memory: in_memory,
           enable_resources: true,
           enable_extensions: true,
           trusted_extensions: [SessionWsServerDemo.Extension],
           extensions: [SessionWsServerDemo.Extension]
         }) do
      {:ok, %{session: session}} ->
        reply = %{
          ok: true,
          type: "session_created",
          session_id: AgentSession.session_id(session),
          model: "#{session.agent.model.provider}/#{session.agent.model.id}"
        }

        {:ok, reply, %{state | session: session}}

      {:error, reason} ->
        {:error, %{ok: false, error: inspect(reason)}, state}
    end
  end

  defp route(%{"type" => "prompt", "text" => text} = data, %{session: nil} = state) do
    {:error, %{ok: false, error: "session_not_initialized", hint: "call create_session first"}, state}
  end

  defp route(%{"type" => "prompt", "text" => text} = data, %{session: session} = state) do
    run_conversation = Map.get(data, "run_conversation", true)

    case AgentSession.prompt(session, text, %{run_conversation: run_conversation}) do
      {:ok, updated} ->
        messages = AgentSession.messages(updated)

        reply = %{
          ok: true,
          type: "prompt_accepted",
          message_count: length(messages),
          run_conversation: run_conversation,
          mode: "ack_plus_snapshot",
          assistant_text: last_assistant_text(messages)
        }

        {:ok, reply, %{state | session: updated}}

      {:error, reason} ->
        {:error, %{ok: false, error: inspect(reason)}, state}
    end
  end

  defp route(%{"type" => "compact"} = data, %{session: nil} = state) do
    {:error, %{ok: false, error: "session_not_initialized"}, state}
  end

  defp route(%{"type" => "compact"} = data, %{session: session} = state) do
    instructions = Map.get(data, "instructions")

    case AgentSession.compact(session, instructions) do
      {:ok, updated, result} ->
        {:ok, %{ok: true, type: "compacted", result: result}, %{state | session: updated}}

      {:error, reason} ->
        {:error, %{ok: false, error: inspect(reason)}, state}
    end
  end

  defp route(%{"type" => "reload"} = data, %{session: nil} = state) do
    {:error, %{ok: false, error: "session_not_initialized"}, state}
  end

  defp route(%{"type" => "reload"} = data, %{session: session} = state) do
    session =
      AgentSession.reload_resources(session, %{
        prompt_paths: Map.get(data, "prompt_paths", []),
        skill_paths: Map.get(data, "skill_paths", [])
      })

    {:ok, %{ok: true, type: "reloaded"}, %{state | session: session}}
  end

  defp route(%{"type" => "get_commands"}, %{session: nil} = state) do
    {:error, %{ok: false, error: "session_not_initialized"}, state}
  end

  defp route(%{"type" => "get_commands"}, %{session: session} = state) do
    commands =
      AgentSession.get_commands(session)
      |> Enum.map(fn cmd ->
        %{
          name: cmd.name,
          source: cmd.source,
          description: cmd.description,
          location: cmd.location,
          path: cmd.path,
          invokable: cmd.invokable
        }
      end)

    {:ok, %{ok: true, type: "commands", commands: commands, version: 1}, state}
  end

  defp route(%{"type" => "diagnostics"}, %{session: nil} = state) do
    {:error, %{ok: false, error: "session_not_initialized"}, state}
  end

  defp route(%{"type" => "diagnostics"}, %{session: session} = state) do
    diagnostics =
      AgentSession.get_diagnostics(session)
      |> Enum.map(fn d -> %{severity: d.severity, message: d.message, source: d.source, path: d.path} end)

    {:ok, %{ok: true, type: "diagnostics", diagnostics: diagnostics}, state}
  end

  defp route(%{"type" => "messages"}, %{session: nil} = state) do
    {:error, %{ok: false, error: "session_not_initialized"}, state}
  end

  defp route(%{"type" => "messages"}, %{session: session} = state) do
    messages =
      AgentSession.messages(session)
      |> Enum.with_index()
      |> Enum.map(fn {m, idx} ->
        %{
          index: idx,
          role: Map.get(m, :role),
          text: message_text(m)
        }
      end)

    {:ok, %{ok: true, type: "messages", count: length(messages), messages: messages}, state}
  end

  defp route(%{"type" => "tools"}, %{session: nil} = state) do
    {:error, %{ok: false, error: "session_not_initialized"}, state}
  end

  defp route(%{"type" => "tools"}, %{session: session} = state) do
    tools =
      session
      |> AgentSession.state()
      |> Agent.get_tools()
      |> Enum.map(fn tool ->
        %{
          name: tool.function.name,
          description: tool.function.description,
          label: tool.label
        }
      end)

    {:ok, %{ok: true, type: "tools", count: length(tools), tools: tools}, state}
  end

  defp route(%{"type" => "stats"}, %{session: nil} = state) do
    {:ok, %{ok: true, type: "stats", initialized: false}, state}
  end
  defp route(%{"type" => "stats"}, %{session: session} = state) do
    manager = AgentSession.session_manager(session)

    entries = Manager.get_entries(manager)

    reply = %{
      ok: true,
      type: "stats",
      initialized: true,
      session_id: AgentSession.session_id(session),
      message_count: length(AgentSession.messages(session)),
      entry_count: length(entries),
      entry_types: Enum.frequencies_by(entries, &to_string(Map.get(&1, :type)))
    }

    {:ok, reply, state}
  end

  defp route(_unknown, state) do
    {:error, %{ok: false, error: "unknown_command"}, state}
  end

  defp last_assistant_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn m ->
      if Map.get(m, :role) == :assistant or Map.get(m, :role) == "assistant" do
        message_text(m)
      else
        nil
      end
    end)
  end

  defp message_text(message) do
    content = Map.get(message, :content)

    cond do
      is_binary(content) ->
        content

      is_list(content) ->
        content
        |> Enum.map(fn part ->
          cond do
            is_binary(part) -> part
            is_map(part) and is_binary(Map.get(part, :text)) -> Map.get(part, :text)
            is_map(part) and is_binary(Map.get(part, "text")) -> Map.get(part, "text")
            true -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      true ->
        nil
    end
  end
end

defmodule SessionWsServerDemo.HealthHandler do
  @behaviour :cowboy_handler

  def init(req, state) do
    body = Jason.encode!(%{ok: true, service: "session_ws_demo", status: "healthy"})

    req =
      :cowboy_req.reply(
        200,
        %{"content-type" => "application/json; charset=utf-8"},
        body,
        req
      )

    {:ok, req, state}
  end
end

defmodule SessionWsServerDemo do
  def run do
    port = String.to_integer(System.get_env("PORT", "8080"))

    dispatch =
      :cowboy_router.compile([
        {:_, [{"/ws", SessionWsServerDemo.Handler, %{}}, {"/health", SessionWsServerDemo.HealthHandler, %{}}]}
      ])

    {:ok, _pid} = :cowboy.start_clear(:session_ws_demo, [{:port, port}], %{env: %{dispatch: dispatch}})

    IO.puts("🛰️  Session WebSocket demo server running on ws://localhost:#{port}/ws")
    IO.puts("🩺 Health endpoint available at http://localhost:#{port}/health")
    IO.puts("Send JSON commands: create_session, prompt, messages, tools, compact, reload, get_commands, diagnostics, stats")

    Process.sleep(:infinity)
  end
end

SessionWsServerDemo.run()
