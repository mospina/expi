# ExpiAI Demo Scripts

This directory contains comprehensive demonstration scripts showcasing the capabilities of the ExpiAI library, with a focus on the Agent module.

## 🚀 Quick Start

1. **Set up your API key:**
   ```bash
   export ANTHROPIC_API_KEY="your-anthropic-key-here"
   ```

2. **Install dependencies:**
   ```bash
   mix deps.get
   ```

3. **Run any demo:**
   ```bash
   elixir quick_agent_demo.exs
   ```

## 📋 Available Demos

### 1. `quick_agent_demo.exs` - Quick Introduction
**Perfect for beginners** - A simple 5-minute demo covering Agent basics.

**Features demonstrated:**
- Basic agent creation with tools
- Simple conversation management  
- Tool execution (calculator)
- Real-time streaming
- Usage statistics

**Runtime:** ~30 seconds  
**Complexity:** Beginner

```bash
elixir quick_agent_demo.exs
```

---

### 2. `agent_demo.exs` - Comprehensive Agent Features
**Complete showcase** - Full feature demonstration with 9 different scenarios.

**Features demonstrated:**
- Agent creation with multiple tools
- Calculator, weather, code analysis, and web search tools
- Real-time streaming with tool execution
- Multi-tool conversations
- Conversation history management
- Usage statistics and cost tracking
- Event monitoring

**Runtime:** ~2-3 minutes  
**Complexity:** Intermediate

```bash
elixir agent_demo.exs
```

---

### 3. `ai_vs_agent_demo.exs` - Module Comparison
**Educational comparison** - Shows differences between AI module and Agent module approaches.

**Features demonstrated:**
- Side-by-side code comparisons
- Performance differences
- Code complexity reduction
- State management comparisons
- Tool handling differences

**Runtime:** ~1-2 minutes  
**Complexity:** Intermediate

```bash
elixir ai_vs_agent_demo.exs
```

---

### 4. `advanced_agent_demo.exs` - Advanced Features
**Production patterns** - Demonstrates sophisticated Agent capabilities for production use.

**Features demonstrated:**
- Message queues with steering vs follow-up patterns
- Comprehensive event monitoring
- Agent cloning and conversation branching  
- Different turn processing modes
- Multi-tool workflow orchestration
- Advanced error handling

**Runtime:** ~3-4 minutes  
**Complexity:** Advanced

```bash
elixir advanced_agent_demo.exs
```

## 🎯 Demo Progression

We recommend running the demos in this order:

1. **Start with `quick_agent_demo.exs`** to understand basics
2. **Try `ai_vs_agent_demo.exs`** to see the value proposition
3. **Explore `agent_demo.exs`** for comprehensive features
4. **Dive into `advanced_agent_demo.exs`** for production patterns

## 🔧 Demo Features Overview

| Feature | Quick | Full | Comparison | Advanced |
|---------|-------|------|------------|----------|
| Basic Conversation | ✅ | ✅ | ✅ | ✅ |
| Tool Execution | ✅ (1 tool) | ✅ (4 tools) | ✅ | ✅ (3 tools) |
| Streaming | ✅ | ✅ | ✅ | ✅ |
| Event Monitoring | ❌ | ✅ | ❌ | ✅ Advanced |
| Message Queues | ❌ | ❌ | ❌ | ✅ |
| Agent Cloning | ❌ | ❌ | ❌ | ✅ |
| Cost Tracking | ✅ | ✅ | ❌ | ✅ |
| Multi-modal | ❌ | ❌ | ❌ | ❌ |
| Turn Processing | ❌ | ❌ | ❌ | ✅ |

## 🛠️ Tool Examples

The demos showcase various tool implementations:

### Calculator Tool
```elixir
# Evaluates mathematical expressions
calculate("15 * 23 + 45") 
# Returns: "15 * 23 + 45 = 390"
```

### Weather Tool (Mock)
```elixir
# Returns mock weather data
get_weather("Tokyo") 
# Returns: Temperature, conditions, humidity
```

### Code Analyzer Tool
```elixir
# Analyzes code for quality and suggestions
analyze_code(elixir_code, "elixir")
# Returns: Line count, suggestions, quality metrics
```

### Web Search Tool (Mock)
```elixir
# Returns mock search results
search_web("Elixir programming language")
# Returns: Relevant links and descriptions
```

## 🎨 Demo Output

All demos feature:
- **🎨 Colorized output** with ANSI colors for better readability
- **📊 Progress indicators** showing what's happening
- **⏱️ Timing information** for performance insights
- **📈 Statistics** including costs, tokens, and usage
- **🔍 Detailed logging** for educational purposes

## 🐛 Troubleshooting

### Common Issues:

**API Key Error:**
```bash
❌ Please set ANTHROPIC_API_KEY environment variable
```
**Solution:** Set your API key: `export ANTHROPIC_API_KEY="your-key"`

**Dependencies Missing:**
```bash
** (Mix) Could not start application expi
```
**Solution:** Run `mix deps.get` first

**Network Issues:**
```bash
❌ Error: network_error
```
**Solution:** Check internet connection and API key validity

## 📚 Learning Path

### For Beginners:
1. Read the [README.md](README.md) overview
2. Run `quick_agent_demo.exs`
3. Explore [docs/agent.md](docs/agent.md)
4. Try `agent_demo.exs`

### For Experienced Developers:
1. Run `ai_vs_agent_demo.exs` to see the differences
2. Dive into `advanced_agent_demo.exs`
3. Review [docs/integration_guide.md](docs/integration_guide.md)
4. Check [docs/migration.md](docs/migration.md) for upgrading

### For Production Use:
1. Study `advanced_agent_demo.exs` patterns
2. Review [docs/agent.md](docs/agent.md) production sections
3. Implement monitoring from event examples
4. Use cost tracking patterns shown in demos

## 🎯 What You'll Learn

After running all demos, you'll understand:

- **Agent vs AI module** - When to use each approach
- **Tool integration** - How to create and use custom tools  
- **Conversation management** - Automatic state handling
- **Event monitoring** - Production observability patterns
- **Message queuing** - Advanced conversation control
- **Cost optimization** - Usage tracking and management
- **Error handling** - Resilient conversation patterns
- **Streaming patterns** - Real-time user experiences

## 🚀 Next Steps

After exploring the demos:

1. **Build your own tools** using the patterns shown
2. **Integrate into your application** using the integration guide
3. **Set up monitoring** using the event patterns
4. **Optimize for production** using the advanced patterns

## 📖 Additional Resources

- [Main Documentation](README.md)
- [Agent Guide](docs/agent.md)  
- [Integration Guide](docs/integration_guide.md)
- [Provider Guide](docs/providers.md)
- [Migration Guide](docs/migration.md)
- [Streaming Guide](docs/streaming.md)

---

**Happy coding with ExpiAI! 🤖✨**
