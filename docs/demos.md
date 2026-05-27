# ExpiAI Demo Scripts

This directory contains demonstration scripts for ExpiAI, including AI, Agent, and the new Session module.

## 🚀 Quick Start

1. **Install dependencies:**
   ```bash
   mix deps.get
   ```

2. **Set API key (for demos that call providers):**
   ```bash
   export ANTHROPIC_API_KEY="your-anthropic-key-here"
   ```

3. **Run a demo from project root:**
   ```bash
   elixir demos/quick_agent_demo.exs
   ```

## 📋 Available Demos

### 1. `quick_agent_demo.exs` - Quick Introduction
**Beginner** demo for basic Agent concepts.

- Agent creation
- Basic prompts
- Tool usage
- Streaming output

```bash
elixir demos/quick_agent_demo.exs
```

---

### 2. `agent_demo.exs` - Comprehensive Agent Features
**Intermediate** showcase with multiple tools and richer orchestration.

- Multi-tool setup
- Multi-turn conversation
- Event/usage patterns

```bash
elixir demos/agent_demo.exs
```

---

### 3. `ai_vs_agent_demo.exs` - Module Comparison
**Intermediate** side-by-side view of low-level AI calls vs Agent workflows.

- API ergonomics comparison
- State handling differences

```bash
elixir demos/ai_vs_agent_demo.exs
```

---

### 4. `advanced_agent_demo.exs` - Advanced Features
**Advanced** agent patterns for production-style flows.

- Queueing (steering/follow-up)
- Event monitoring
- Branching/cloning patterns

```bash
elixir demos/advanced_agent_demo.exs
```

---

### 5. `real_streaming_demo.exs` - Real Streaming Scenarios
**Intermediate** practical streaming behavior with realistic prompts.

- Synchronous vs streaming comparison
- Event-by-event streaming output
- Latency and throughput stats

```bash
elixir demos/real_streaming_demo.exs
```

---

### 6. `session_lifecycle_demo.exs` - Session Extensibility Walkthrough ✅ NEW
**Intermediate** demo focused on Session runtime + extensibility layers.

- `Expi.Session.create_session/1` with resource/extension feature flags
- Prompt template loading and `/template ...` expansion
- Skill loading and `/skill:name ...` expansion
- Extension command registration (`/echo`) and input transformation hooks
- Session compaction and diagnostics surface

_No provider call required by default (`run_conversation: false`)._

```bash
elixir demos/session_lifecycle_demo.exs
```

---

### 7. `session_cli_coding_assistant_demo.exs` - CLI Coding Assistant ✅ NEW
**Advanced** minimal terminal demo for a Session-based coding assistant.

- Session-based conversation loop (ephemeral by default)
- Provider-backed responses (`run_conversation: true`)
- Default built-in tool exposure (pi-style defaults)
- Simple interaction model: type prompt, Enter to send, `/quit` to exit
- Basic status + recent conversation visibility for coding-assistant flow

```bash
elixir demos/session_cli_coding_assistant_demo.exs
```

Suggested success criteria:
- Demo starts without extra project setup beyond normal demo prerequisites
- User can send at least one prompt and receive an assistant response
- User can exit cleanly via keyboard shortcut

---

### 8. `session_ws_server_demo.exs` - Lightweight WebSocket Server ✅ NEW
**Advanced** lightweight WebSocket server wrapping Session runtime.

- Per-socket session state
- JSON commands over WS (`create_session`, `prompt`, `compact`, `reload`, `get_commands`, `diagnostics`, `stats`)
- Command inventory response with source metadata (`extension`/`prompt`/`skill`)
- HTTP health endpoint at `/health` for quick orchestration checks
- Useful as a minimal integration template

```bash
elixir demos/session_ws_server_demo.exs
```

Health check:

```bash
curl -s http://localhost:8080/health
```

Test with:

```bash
npx wscat -c ws://localhost:8080/ws
```

Example commands:

```json
{"type":"create_session","provider":"anthropic","model_id":"claude-sonnet-3-6","in_memory":true}
{"type":"prompt","text":"Draft release notes","run_conversation":false}
{"type":"compact","instructions":"Keep key actions"}
{"type":"get_commands"}
{"type":"diagnostics"}
{"type":"stats"}
```

## 🎯 Suggested Run Order

1. `quick_agent_demo.exs`
2. `ai_vs_agent_demo.exs`
3. `agent_demo.exs`
4. `real_streaming_demo.exs`
5. `session_lifecycle_demo.exs`
6. `advanced_agent_demo.exs`
7. `session_cli_coding_assistant_demo.exs`
8. `session_ws_server_demo.exs`

## 🧭 Notes

- Session demos are designed to highlight lifecycle + extensibility capabilities.
- `session_ws_server_demo.exs` is intentionally minimal and suitable for local experimentation.
- If you enable `run_conversation: true`, ensure provider credentials are set.
- See `docs/session.md` for dispatch order, discovery defaults, and migration guidance.
