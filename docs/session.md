# Expi Session Module

`Expi.Session` provides durable, branch-aware session orchestration on top of `Expi.Agent`.

## Highlights

- Append-only JSONL persistence compatible with pi-mono session entries
- In-memory or persisted session manager modes
- Session runtime wrapper (`Expi.Session.AgentSession`) for prompt/lifecycle operations
- Branch navigation and branch summaries
- Manual compaction support with persisted compaction entries

## Quick start

```elixir
{:ok, model} = Expi.AI.get_model("anthropic", "claude-sonnet-3-6")

{:ok, %{session: session}} = Expi.Session.create_session(%{
  model: model,
  cwd: File.cwd!()
})

{:ok, session} = Expi.Session.AgentSession.prompt(session, "Review current project structure")
{:ok, session, _result} = Expi.Session.AgentSession.compact(session)
```

## Storage model

Session files are newline-delimited JSON records:

1. Session header (`type: "session"`)
2. Append-only session entries (`message`, `model_change`, `thinking_level_change`, `compaction`, `label`, etc.)

Each entry has an `id`, `parentId`, and `timestamp`, enabling branch traversal and context reconstruction.
