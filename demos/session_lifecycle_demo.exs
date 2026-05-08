#!/usr/bin/env elixir

# Session lifecycle + extensibility demo
#
# Demonstrates:
# - resource loader (prompts + skills)
# - extension runner (command + input hook)
# - deterministic dispatch order behavior
#
# Usage:
#   cd expi
#   elixir demos/session_lifecycle_demo.exs

Mix.install([
  {:expi, path: "."}
])

defmodule SessionLifecycleDemo.Extension do
  @behaviour Expi.Session.Extension

  def register(_ctx) do
    %{
      commands: [
        %{
          name: "echo",
          description: "Echo text into the session as a user prompt",
          handler: fn args, session, _ctx ->
            Expi.Session.AgentSession.prompt(session, "[echo] " <> args, %{run_conversation: false, expand_resources: false})
          end
        }
      ],
      hooks: %{
        input: [
          fn text, images, _ctx ->
            if String.starts_with?(text, "!!up ") do
              {:transform, String.upcase(String.replace_prefix(text, "!!up ", "")), images}
            else
              :continue
            end
          end
        ]
      }
    }
  end
end

defmodule SessionLifecycleDemo do
  alias Expi.Session
  alias Expi.Session.AgentSession
  alias Expi.Session.Manager
  alias Expi.Types.Model

  def run do
    IO.puts("🧭 Expi Session Lifecycle + Extensibility Demo")
    IO.puts(String.duplicate("=", 48))

    demo_root = Path.join(System.tmp_dir!(), "expi-session-demo-#{System.system_time(:millisecond)}")
    File.mkdir_p!(Path.join(demo_root, ".pi/prompts"))
    File.mkdir_p!(Path.join(demo_root, ".pi/skills/release-notes"))

    File.write!(
      Path.join(demo_root, ".pi/prompts/summarize.md"),
      """
      ---
      description: Summarize content quickly
      ---
      Summarize the following text in 3 bullets:\n\n$ARGUMENTS
      """
    )

    File.write!(
      Path.join(demo_root, ".pi/skills/release-notes/SKILL.md"),
      """
      ---
      name: release-notes
      description: Use this skill for release notes generation
      disable-model-invocation: false
      ---
      # Release Notes Skill
     
      Collect key changes, risks, and rollback notes.
      """
    )

    {:ok, %{session: session}} =
      Session.create_session(%{
        model: demo_model(),
        in_memory: true,
        cwd: demo_root,
        thinking_level: :medium,
        system_prompt: "You are a session demo assistant",
        enable_resources: true,
        enable_extensions: true,
        trusted_extensions: [SessionLifecycleDemo.Extension],
        extensions: [SessionLifecycleDemo.Extension]
      })

    IO.puts("✅ Session created")
    IO.puts("   session_id: #{AgentSession.session_id(session)}")

    commands = AgentSession.get_commands(session)
    IO.puts("\n📚 Available commands:")
    Enum.each(commands, fn cmd ->
      IO.puts("   /#{cmd.name} (#{cmd.source})")
    end)

    {:ok, session} = AgentSession.prompt(session, "/echo hello extension command")
    {:ok, session} = AgentSession.prompt(session, "!!up this is transformed by input hook", %{run_conversation: false})
    {:ok, session} = AgentSession.prompt(session, "/summarize Expi now supports resource loading and extension dispatch", %{run_conversation: false})
    {:ok, session} = AgentSession.prompt(session, "/skill:release-notes draft notes for v1", %{run_conversation: false})

    IO.puts("\n✅ Exercised extension command + input transform + prompt template + skill expansion")

    {:ok, session, compaction} = AgentSession.compact(session, "Focus on action-oriented summary")

    IO.puts("✅ Compaction executed")
    IO.puts("   first_kept_entry_id: #{compaction.first_kept_entry_id}")

    entries = Manager.get_entries(AgentSession.session_manager(session))
    counts = Enum.frequencies_by(entries, &Map.get(&1, :type))

    IO.puts("\n📊 Entry counts:")
    Enum.each(counts, fn {type, count} -> IO.puts("   #{type}: #{count}") end)

    diagnostics = AgentSession.get_diagnostics(session)

    if diagnostics != [] do
      IO.puts("\n⚠️ Diagnostics:")
      Enum.each(diagnostics, fn d ->
        IO.puts("   [#{d.severity}] #{d.message}")
      end)
    end

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
