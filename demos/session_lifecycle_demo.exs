#!/usr/bin/env elixir

# Session lifecycle demo
#
# Demonstrates Expi.Session + Expi.Session.AgentSession without requiring
# external API calls (run_conversation: false).
#
# Usage:
#   cd expi
#   elixir demos/session_lifecycle_demo.exs

Mix.install([
  {:expi, path: "."}
])

defmodule SessionLifecycleDemo do
  alias Expi.Session
  alias Expi.Session.AgentSession
  alias Expi.Session.Manager
  alias Expi.Types.Model

  def run do
    IO.puts("🧭 Expi Session Lifecycle Demo")
    IO.puts(String.duplicate("=", 34))

    {:ok, %{session: session}} =
      Session.create_session(%{
        model: demo_model(),
        in_memory: true,
        thinking_level: :medium,
        system_prompt: "You are a session demo assistant"
      })

    IO.puts("✅ Session created")
    IO.puts("   session_id: #{AgentSession.session_id(session)}")

    {:ok, session} = AgentSession.prompt(session, "Plan a migration checklist.", %{run_conversation: false})
    {:ok, session} = AgentSession.prompt(session, "Include risks and mitigations.", %{run_conversation: false})
    {:ok, session} = AgentSession.prompt(session, "Add rollout and rollback steps.", %{run_conversation: false})
    {:ok, session} = AgentSession.prompt(session, "Summarize in bullet points.", %{run_conversation: false})

    IO.puts("✅ Appended 4 user messages (persisted as session entries)")

    {:ok, session, compaction} = AgentSession.compact(session, "Focus on action-oriented summary")

    IO.puts("✅ Compaction executed")
    IO.puts("   first_kept_entry_id: #{compaction.first_kept_entry_id}")
    IO.puts("   tokens_before (estimated): #{compaction.tokens_before}")

    entries = Manager.get_entries(AgentSession.session_manager(session))
    counts = Enum.frequencies_by(entries, &Map.get(&1, :type))

    IO.puts("\n📊 Entry counts:")
    Enum.each(counts, fn {type, count} -> IO.puts("   #{type}: #{count}") end)

    branch_target =
      entries
      |> Enum.find(fn e -> Map.get(e, :type) == :message end)
      |> Map.get(:id)

    session = AgentSession.branch_with_summary(session, branch_target, "Branching to explore an alternate plan")

    IO.puts("\n🌿 Branch summary appended from entry: #{branch_target}")

    context = Manager.build_session_context(AgentSession.session_manager(session))
    IO.puts("🧠 Rebuilt context messages: #{length(context.messages)}")

    IO.puts("\n🎉 Demo complete")
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
      cost: %Expi.Types.Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 8_000,
      headers: %{},
      compat: %{}
    }
  end
end

SessionLifecycleDemo.run()
