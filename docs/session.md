# Expi Session Module

`Expi.Session` provides durable, branch-aware session orchestration on top of `Expi.Agent`, now with optional extensibility layers for prompts, skills, and extensions.

## Highlights

- Append-only JSONL persistence compatible with pi-mono session entries
- In-memory or persisted session manager modes
- Session runtime wrapper (`Expi.Session.AgentSession`) for prompt/lifecycle operations
- Branch navigation and branch summaries
- Manual compaction support with persisted compaction entries
- Optional **resource loader** (prompt templates + skills)
- Optional **extension runner** (custom commands, tools, input hooks)
- Deterministic Session dispatch order for slash/input handling

## Dispatch order

When enabled, Session prompt handling follows this order:

1. Extension command handling (`/command`)
2. Extension input hooks/interceptors
3. Skill command expansion (`/skill:name ...`)
4. Prompt template expansion (`/template ...`)
5. Normal agent turn execution

This order keeps behavior predictable across CLI/server integrations.

## Quick start

```elixir
{:ok, model} = Expi.AI.get_model("anthropic", "claude-sonnet-3-6")

{:ok, %{session: session}} = Expi.Session.create_session(%{
  model: model,
  cwd: File.cwd!(),
  enable_resources: true,
  enable_extensions: false
})

{:ok, session} = Expi.Session.AgentSession.prompt(session, "Review current project structure")
{:ok, session, _result} = Expi.Session.AgentSession.compact(session)
```

## Extensibility options

`Expi.Session.create_session/1` supports:

- `:enable_resources` - enables prompt/skill loading
- `:enable_extensions` - enables extension runtime
- `:extensions` - extension modules implementing `Expi.Session.Extension`
- `:trusted_extensions` - allow-list for extension loading
- `:prompt_paths` - additional prompt template paths
- `:skill_paths` - additional skill paths

### Discovery defaults (when resources enabled)

- Prompts:
  - `<agent_dir>/prompts`
  - `<cwd>/.pi/prompts`
- Skills:
  - `<agent_dir>/skills`
  - `<cwd>/.pi/skills`
  - `~/.agents/skills`
  - ancestor `.agents/skills` directories from `cwd`

Agent dir defaults to `EXPI_CODING_AGENT_DIR`, then `PI_CODING_AGENT_DIR`, then `~/.pi/agent`.

## Runtime APIs

Use these on `Expi.Session.AgentSession`:

- `prompt/3` - send input with dispatch behavior
- `reload_resources/2` - reload prompt/skill/extension runtime inputs
- `get_commands/1` - discover extension/prompt/skill commands with metadata
- `get_diagnostics/1` - inspect resource/extension warnings and collisions

## Storage model

Session files are newline-delimited JSON records:

1. Session header (`type: "session"`)
2. Append-only session entries (`message`, `model_change`, `thinking_level_change`, `compaction`, `label`, etc.)

Each entry has an `id`, `parentId`, and `timestamp`, enabling branch traversal and context reconstruction.

## Migration guidance

Existing Session flows continue to work unchanged by default.

Recommended rollout:

1. Enable `:enable_resources` first and validate command expansion behavior.
2. Enable `:enable_extensions` with a strict `:trusted_extensions` allow-list.
3. Introduce command inventory (`get_commands/1`) for server/RPC clients.
4. Use `get_diagnostics/1` to surface conflicts before full rollout.
