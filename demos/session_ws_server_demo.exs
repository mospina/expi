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
#   > {"type":"prompt","text":"Draft release notes","run_conversation":false}
#   > {"type":"compact","instructions":"Keep only key actions"}
#   > {"type":"stats"}

Mix.install([
  {:expi, path: "."},
  {:jason, "~> 1.4"},
  {:cowboy, "~> 2.12"}
])

defmodule SessionWsServerDemo.Handler do
  @behaviour :cowboy_websocket

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

    case Session.create_session(%{provider: provider, model_id: model_id, in_memory: in_memory}) do
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
    run_conversation = Map.get(data, "run_conversation", false)

    case AgentSession.prompt(session, text, %{run_conversation: run_conversation}) do
      {:ok, updated} ->
        reply = %{
          ok: true,
          type: "prompt_accepted",
          message_count: length(AgentSession.messages(updated)),
          run_conversation: run_conversation
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
    IO.puts("Send JSON commands: create_session, prompt, compact, stats")

    Process.sleep(:infinity)
  end
end

SessionWsServerDemo.run()
