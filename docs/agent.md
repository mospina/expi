# Expi Agent Guide

The Expi Agent module provides sophisticated conversation orchestration, state management, and tool execution for AI applications. This guide covers everything from basic usage to advanced patterns.

## Table of Contents

1. [Agent Overview](#agent-overview)
2. [Core Concepts](#core-concepts)
3. [Basic Usage](#basic-usage)
4. [State Management](#state-management)
5. [Tool Integration](#tool-integration)
6. [Message Handling](#message-handling)
7. [Event System](#event-system)
8. [Streaming](#streaming)
9. [Advanced Patterns](#advanced-patterns)
10. [Production Considerations](#production-considerations)

## Agent Overview

The Agent module sits above the low-level AI module and provides:

- **Conversation State**: Automatic management of conversation history
- **Tool Orchestration**: Automatic tool calling and result integration
- **Message Queuing**: Sophisticated message handling with steering and follow-up
- **Event System**: Fine-grained lifecycle events for monitoring and debugging
- **Streaming Support**: Real-time response streaming with callbacks
- **Error Handling**: Robust error recovery and retry mechanisms

### Architecture

```
┌─────────────────┐
│   Your App      │
├─────────────────┤
│   Agent Module  │  ← High-level conversation orchestration
├─────────────────┤
│   AI Module     │  ← Provider-specific API calls
├─────────────────┤
│   Providers     │  ← Anthropic, Google, Ollama
└─────────────────┘
```

## Core Concepts

### Agent State

An agent maintains conversation state including:

- **Model Configuration**: Provider, model ID, and settings
- **System Prompt**: Context and behavior instructions
- **Message History**: Complete conversation log
- **Tools**: Available functions and their configurations
- **Metadata**: Creation time, configuration, statistics

### Message Flow

```
User Input → Message Queue → Agent Processing → Tool Execution → LLM Response → Event Emission
```

### Tool Integration

Tools are functions that the AI can call automatically:

1. **Registration**: Tools are registered with the agent
2. **Discovery**: AI discovers appropriate tools for tasks
3. **Execution**: Tools run concurrently with proper error isolation
4. **Integration**: Results are seamlessly integrated into conversation

## Basic Usage

### Creating an Agent

```elixir
alias Expi.Agent
alias Expi.AI

# Get a model
{:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")

# Create a basic agent
{:ok, agent} = Agent.create(model, %{
  system_prompt: "You are a helpful programming assistant"
})

# Create with configuration
{:ok, agent} = Agent.create(model, %{
  system_prompt: "You are a helpful assistant",
  thinking_level: :medium,
  tools: []
})
```

### Simple Conversation

```elixir
# Send a message
{:ok, agent, response} = Agent.send_message(agent, "Hello! How can you help me?")

IO.puts("Assistant: #{extract_text(response.content)}")

# Continue the conversation  
{:ok, agent, response} = Agent.send_message(agent, "I need help with Elixir pattern matching")

# Agent automatically maintains conversation history
messages = Agent.get_messages(agent)
IO.puts("Conversation has #{length(messages)} messages")
```

### Helper Functions

```elixir
defmodule MyApp.AgentHelper do
  def extract_text(content) when is_binary(content), do: content
  def extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map(& &1.text)
    |> Enum.join(" ")
  end
  
  def print_conversation(agent) do
    agent
    |> Agent.get_messages()
    |> Enum.each(fn message ->
      role = String.upcase(to_string(message.role))
      content = extract_text(message.content)
      IO.puts("#{role}: #{content}")
    end)
  end
end
```

## State Management

### Agent Configuration

```elixir
# Get current configuration
config = Agent.get_config(agent)
%{
  model: model,
  system_prompt: system_prompt,
  max_context_length: max_length,
  temperature: temperature,
  streaming: streaming_enabled
}

# Get agent statistics  
stats = Agent.get_stats(agent)
%{
  created_at: timestamp,
  message_count: count,
  tool_count: tool_count,
  total_tokens: tokens,
  total_cost: cost
}
```

### State Cloning

Create independent conversation branches:

```elixir
# Create a conversation branch
original_agent = agent
branch_agent = Agent.clone(agent)

# Both agents start with the same history
assert Agent.get_messages(original_agent) == Agent.get_messages(branch_agent)

# But diverge independently
{:ok, original_agent, _} = Agent.send_message(original_agent, "Path A")
{:ok, branch_agent, _} = Agent.send_message(branch_agent, "Path B")

# Now they have different histories
assert Agent.get_messages(original_agent) != Agent.get_messages(branch_agent)
```

### State Validation

```elixir
# Validate agent state
case Agent.validate(agent) do
  :ok -> 
    IO.puts("Agent is valid")
  
  {:error, reason} ->
    IO.puts("Agent validation failed: #{reason}")
end

# Check if agent is valid (boolean)
if Agent.valid?(agent) do
  proceed_with_conversation(agent)
else
  handle_invalid_agent(agent)
end
```

## Tool Integration

### Creating Tools

Tools are functions that the AI can call to perform actions:

```elixir
# Simple calculator tool
{:ok, calculator} = Expi.Agent.Tool.new(
  "calculate",
  "Perform mathematical calculations",
  %{
    type: :object,
    properties: %{
      expression: %{
        type: :string, 
        description: "Mathematical expression to evaluate"
      }
    },
    required: ["expression"]
  },
  "Calculator",
  fn _tool_call_id, params, _abort_signal, _update_callback ->
    expression = params["expression"]
    
    try do
      {result, _} = Code.eval_string(expression)
      
      {:ok, %Expi.Agent.Types.AgentToolResult{
        content: [
          %Expi.Types.TextContent{
            type: :text, 
            text: "The result is: #{result}"
          }
        ],
        details: %{
          expression: expression,
          result: result,
          calculated_at: System.system_time(:millisecond)
        }
      }}
    rescue
      error ->
        {:error, "Calculation failed: #{Exception.message(error)}"}
    end
  end
)

# Add tool to agent
agent = Agent.add_tool(agent, calculator)
```

### Advanced Tool Examples

#### Web Search Tool

```elixir
defmodule MyApp.SearchTool do
  def create do
    {:ok, tool} = Expi.Agent.Tool.new(
      "search_web",
      "Search the web for information",
      %{
        type: :object,
        properties: %{
          query: %{type: :string, description: "Search query"},
          max_results: %{type: :integer, minimum: 1, maximum: 10, default: 5}
        },
        required: ["query"]
      },
      "Web Search",
      &execute/4
    )
    tool
  end

  defp execute(_tool_call_id, params, _abort_signal, update_callback) do
    query = params["query"]
    max_results = params["max_results"] || 5
    
    # Simulate progress updates
    if update_callback do
      update_callback.(%Expi.Agent.Types.AgentToolResult{
        content: [],
        details: %{status: :searching, query: query}
      })
    end
    
    # Perform search (implement your search logic)
    results = perform_web_search(query, max_results)
    
    content = [
      %Expi.Types.TextContent{
        type: :text,
        text: format_search_results(results)
      }
    ]
    
    {:ok, %Expi.Agent.Types.AgentToolResult{
      content: content,
      details: %{
        query: query,
        results_count: length(results),
        results: results
      }
    }}
  end

  defp perform_web_search(query, max_results) do
    # Mock implementation - replace with actual search API
    [
      %{title: "Result 1", url: "https://example.com/1", snippet: "Sample result..."},
      %{title: "Result 2", url: "https://example.com/2", snippet: "Another result..."}
    ]
    |> Enum.take(max_results)
  end

  defp format_search_results(results) do
    results
    |> Enum.with_index(1)
    |> Enum.map(fn {result, index} ->
      "#{index}. #{result.title}\n   #{result.url}\n   #{result.snippet}"
    end)
    |> Enum.join("\n\n")
  end
end
```

#### File Operations Tool

```elixir
defmodule MyApp.FileTool do
  def create do
    {:ok, tool} = Expi.Agent.Tool.new(
      "file_operations",
      "Read, write, and manipulate files",
      %{
        type: :object,
        properties: %{
          operation: %{type: :string, enum: ["read", "write", "list"]},
          path: %{type: :string, description: "File or directory path"},
          content: %{type: :string, description: "Content to write (for write operations)"}
        },
        required: ["operation", "path"]
      },
      "File Operations",
      &execute/4
    )
    tool
  end

  defp execute(_tool_call_id, params, _abort_signal, _update_callback) do
    operation = params["operation"]
    path = params["path"]
    content = params["content"]
    
    # Security: Restrict to safe directories
    case validate_path(path) do
      :ok ->
        case operation do
          "read" -> read_file(path)
          "write" -> write_file(path, content)
          "list" -> list_directory(path)
        end
      
      {:error, reason} ->
        {:error, "Access denied: #{reason}"}
    end
  end

  defp validate_path(path) do
    # Implement security checks
    cond do
      String.contains?(path, "..") ->
        {:error, "Path traversal not allowed"}
      
      not String.starts_with?(path, "/safe/directory/") ->
        {:error, "Access restricted to safe directory"}
      
      true ->
        :ok
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, %Expi.Agent.Types.AgentToolResult{
          content: [
            %Expi.Types.TextContent{
              type: :text,
              text: "File content:\n\n#{content}"
            }
          ],
          details: %{operation: :read, path: path, size: byte_size(content)}
        }}
      
      {:error, reason} ->
        {:error, "Failed to read file: #{reason}"}
    end
  end

  defp write_file(path, content) when is_binary(content) do
    case File.write(path, content) do
      :ok ->
        {:ok, %Expi.Agent.Types.AgentToolResult{
          content: [
            %Expi.Types.TextContent{
              type: :text,
              text: "Successfully wrote #{byte_size(content)} bytes to #{path}"
            }
          ],
          details: %{operation: :write, path: path, bytes_written: byte_size(content)}
        }}
      
      {:error, reason} ->
        {:error, "Failed to write file: #{reason}"}
    end
  end

  defp write_file(_path, nil) do
    {:error, "Content is required for write operations"}
  end

  defp list_directory(path) do
    case File.ls(path) do
      {:ok, files} ->
        file_list = Enum.join(files, "\n")
        
        {:ok, %Expi.Agent.Types.AgentToolResult{
          content: [
            %Expi.Types.TextContent{
              type: :text,
              text: "Directory contents:\n\n#{file_list}"
            }
          ],
          details: %{operation: :list, path: path, file_count: length(files), files: files}
        }}
      
      {:error, reason} ->
        {:error, "Failed to list directory: #{reason}"}
    end
  end
end
```

### Tool Management

```elixir
# Add multiple tools
search_tool = MyApp.SearchTool.create()
file_tool = MyApp.FileTool.create()
calc_tool = create_calculator_tool()

agent = agent
|> Agent.add_tool(search_tool)
|> Agent.add_tool(file_tool)  
|> Agent.add_tool(calc_tool)

# List available tools
tools = Agent.get_tools(agent)
tool_names = Enum.map(tools, & &1.function.name)
IO.puts("Available tools: #{Enum.join(tool_names, ", ")}")

# Remove a tool
agent = Agent.remove_tool(agent, "file_operations")

# Execute tools manually (for testing)
{:ok, results} = Agent.execute_pending_tools(agent, ["calculate"], %{
  "calculate" => %{"expression" => "2 + 2"}
})
```

## Message Handling

The Agent supports sophisticated message queuing with steering and follow-up patterns:

### Message Types

- **User Messages**: Direct user input
- **Steering Messages**: High-priority interruptions that take precedence
- **Follow-up Messages**: Natural conversation continuations

### Message Queue Operations

```elixir
# Add regular user message
{:ok, agent, response} = Agent.send_message(agent, "Tell me about Elixir")

# Add steering message (interrupts current context)
agent = Agent.add_steering_message(agent, "Actually, focus on pattern matching specifically")

# Add follow-up message (queued for natural flow)
agent = Agent.add_follow_up_message(agent, "Can you provide code examples?")

# Process all pending messages
{:ok, agent, turn_data} = Agent.process_turn(agent)
```

### Message Processing Modes

```elixir
# Process all messages at once (default)
{:ok, agent, turn_data} = Agent.process_turn(agent, %{
  steering_mode: :all,
  follow_up_mode: :all
})

# Process messages one at a time
{:ok, agent, turn_data} = Agent.process_turn(agent, %{
  steering_mode: :one_at_a_time,
  follow_up_mode: :one_at_a_time
})

# Mixed mode
{:ok, agent, turn_data} = Agent.process_turn(agent, %{
  steering_mode: :all,           # Process all steering messages together
  follow_up_mode: :one_at_a_time # Process follow-ups individually
})
```

### Message Transformations

```elixir
# Custom message transformation
transform_fn = fn messages ->
  # Example: Summarize old messages to save context
  if length(messages) > 20 do
    {recent, old} = Enum.split(messages, -10)
    summary = create_summary(old)
    
    summary_message = %Expi.Types.UserMessage{
      role: :user,
      content: "Previous conversation summary: #{summary}",
      timestamp: System.system_time(:millisecond)
    }
    
    [summary_message | recent]
  else
    messages
  end
end

{:ok, agent, response} = Agent.send_message(agent, "Continue our conversation", %{
  transform_context: transform_fn
})
```

## Event System

The Agent emits detailed lifecycle events for monitoring and debugging:

### Event Types

```elixir
# Agent lifecycle events
:agent_start, :agent_end

# Turn processing events  
:turn_start, :turn_end

# Message processing events
:message_start, :message_end, :message_processed

# Tool execution events
:tool_start, :tool_end, :tool_progress, :tool_error

# Streaming events
:stream_start, :stream_chunk, :stream_end
```

### Event Monitoring

```elixir
event_callback = fn event ->
  case event.type do
    :agent_start ->
      Logger.info("Agent started processing")
      
    :turn_start ->
      Logger.info("Turn started", %{
        turn_id: event.turn_id,
        message_count: length(event.messages)
      })
      
    :tool_start ->
      Logger.info("Tool execution started", %{
        tool_name: event.tool_name,
        tool_call_id: event.tool_call_id,
        args: event.args
      })
      
    :tool_end ->
      Logger.info("Tool execution completed", %{
        tool_name: event.tool_name,
        duration_ms: event.duration_ms,
        success: not event.is_error
      })
      
    :turn_end ->
      Logger.info("Turn completed", %{
        duration_ms: event.duration_ms,
        tools_executed: length(event.tool_results)
      })
      
    _ ->
      :ok
  end
end

{:ok, agent, turn_data} = Agent.process_turn(agent, %{
  event_callback: event_callback
})
```

### Custom Event Handlers

```elixir
defmodule MyApp.AgentMonitor do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def create_callback do
    fn event ->
      GenServer.cast(__MODULE__, {:agent_event, event})
    end
  end
  
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  # Server implementation
  def init(_opts) do
    state = %{
      turns_processed: 0,
      tools_executed: 0,
      total_duration: 0,
      errors: []
    }
    {:ok, state}
  end

  def handle_cast({:agent_event, event}, state) do
    new_state = case event.type do
      :turn_end ->
        %{state |
          turns_processed: state.turns_processed + 1,
          total_duration: state.total_duration + event.duration_ms
        }
        
      :tool_end ->
        %{state | tools_executed: state.tools_executed + 1}
        
      :tool_error ->
        error_info = %{
          tool_name: event.tool_name,
          error: event.error,
          timestamp: System.system_time(:millisecond)
        }
        %{state | errors: [error_info | state.errors]}
        
      _ ->
        state
    end
    
    {:noreply, new_state}
  end

  def handle_call(:get_metrics, _from, state) do
    metrics = %{
      turns_processed: state.turns_processed,
      tools_executed: state.tools_executed,
      average_turn_duration: average_duration(state),
      error_count: length(state.errors),
      recent_errors: Enum.take(state.errors, 5)
    }
    {:reply, metrics, state}
  end

  defp average_duration(%{turns_processed: 0}), do: 0
  defp average_duration(state) do
    state.total_duration / state.turns_processed
  end
end

# Usage
{:ok, _} = MyApp.AgentMonitor.start_link([])
callback = MyApp.AgentMonitor.create_callback()

{:ok, agent, _} = Agent.process_turn(agent, %{event_callback: callback})

# Check metrics
%{turns_processed: turns, average_turn_duration: avg_duration} = 
  MyApp.AgentMonitor.get_metrics()
```

## Streaming

### Basic Streaming

```elixir
# Stream agent responses
{:ok, agent, response} = Agent.stream_response(agent, fn event ->
  case event.type do
    :start ->
      IO.puts("🎯 Agent started responding...")
      
    :text_delta ->
      IO.write(event.delta)
      
    :thinking_delta ->
      IO.write("[thinking: #{event.delta}]")
      
    :done ->
      IO.puts("\n✅ Response complete!")
      
    :error ->
      IO.puts("\n❌ Error: #{event.error}")
  end
end)
```

### Advanced Streaming with State

```elixir
defmodule MyApp.StreamHandler do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def create_callback(pid \\ __MODULE__) do
    fn event ->
      GenServer.cast(pid, {:stream_event, event})
    end
  end
  
  def get_accumulated_response(pid \\ __MODULE__) do
    GenServer.call(pid, :get_response)
  end

  # Server implementation
  def init(_opts) do
    state = %{
      content: "",
      thinking: "",
      status: :waiting,
      events: []
    }
    {:ok, state}
  end

  def handle_cast({:stream_event, event}, state) do
    new_state = %{state | events: [event | state.events]}
    
    updated_state = case event.type do
      :start ->
        %{new_state | status: :streaming}
        
      :text_delta ->
        %{new_state | content: state.content <> event.delta}
        
      :thinking_delta ->
        %{new_state | thinking: state.thinking <> event.delta}
        
      :done ->
        %{new_state | status: :completed}
        
      :error ->
        %{new_state | status: {:error, event.error}}
        
      _ ->
        new_state
    end
    
    {:noreply, updated_state}
  end

  def handle_call(:get_response, _from, state) do
    response = %{
      content: state.content,
      thinking: state.thinking,
      status: state.status,
      event_count: length(state.events)
    }
    {:reply, response, state}
  end
end

# Usage
{:ok, _} = MyApp.StreamHandler.start_link([])
callback = MyApp.StreamHandler.create_callback()

{:ok, agent, _} = Agent.stream_response(agent, callback)

# Get accumulated response
%{content: content, thinking: thinking, status: status} = 
  MyApp.StreamHandler.get_accumulated_response()
```

## Advanced Patterns

### Agent Pools

For high-concurrency applications:

```elixir
defmodule MyApp.AgentPool do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def get_agent(user_id) do
    GenServer.call(__MODULE__, {:get_agent, user_id})
  end
  
  def return_agent(user_id, agent) do
    GenServer.cast(__MODULE__, {:return_agent, user_id, agent})
  end
  
  def send_message(user_id, message) do
    GenServer.call(__MODULE__, {:send_message, user_id, message})
  end

  # Server implementation
  def init(opts) do
    model_config = Keyword.get(opts, :model_config)
    max_agents = Keyword.get(opts, :max_agents, 100)
    
    state = %{
      model_config: model_config,
      agents: %{},
      max_agents: max_agents,
      agent_count: 0
    }
    {:ok, state}
  end

  def handle_call({:get_agent, user_id}, _from, state) do
    case Map.get(state.agents, user_id) do
      nil ->
        if state.agent_count < state.max_agents do
          case create_agent(state.model_config) do
            {:ok, agent} ->
              new_state = %{state |
                agents: Map.put(state.agents, user_id, agent),
                agent_count: state.agent_count + 1
              }
              {:reply, {:ok, agent}, new_state}
            
            error ->
              {:reply, error, state}
          end
        else
          {:reply, {:error, :pool_exhausted}, state}
        end
        
      agent ->
        {:reply, {:ok, agent}, state}
    end
  end

  def handle_call({:send_message, user_id, message}, _from, state) do
    case Map.get(state.agents, user_id) do
      nil ->
        {:reply, {:error, :agent_not_found}, state}
        
      agent ->
        case Agent.send_message(agent, message) do
          {:ok, updated_agent, response} ->
            new_state = %{state |
              agents: Map.put(state.agents, user_id, updated_agent)
            }
            {:reply, {:ok, response}, new_state}
            
          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_cast({:return_agent, user_id, agent}, state) do
    new_state = %{state |
      agents: Map.put(state.agents, user_id, agent)
    }
    {:noreply, new_state}
  end

  defp create_agent(model_config) do
    {:ok, model} = Expi.AI.get_model(model_config.provider, model_config.model_id)
    
    Agent.create(model, %{
      system_prompt: model_config.system_prompt,
      tools: model_config.tools || []
    })
  end
end
```

### Conversation Templates

```elixir
defmodule MyApp.ConversationTemplates do
  def create_coding_assistant(model) do
    coding_tools = [
      create_code_executor_tool(),
      create_code_formatter_tool(),
      create_documentation_tool()
    ]
    
    Agent.create(model, %{
      system_prompt: """
      You are an expert programming assistant. You help developers write, debug, 
      and improve their code. You have access to tools for executing code, 
      formatting, and generating documentation.
      
      Always explain your reasoning and provide clear, well-commented code examples.
      When debugging, walk through the problem step by step.
      """,
      tools: coding_tools,
      thinking_level: :medium
    })
  end
  
  def create_research_assistant(model) do
    research_tools = [
      create_web_search_tool(),
      create_document_analyzer_tool(),
      create_citation_generator_tool()
    ]
    
    Agent.create(model, %{
      system_prompt: """
      You are a research assistant that helps find, analyze, and synthesize information.
      You have access to web search, document analysis, and citation tools.
      
      Always provide sources for your information and maintain academic rigor.
      Structure your responses clearly with proper citations.
      """,
      tools: research_tools,
      thinking_level: :high
    })
  end
  
  def create_customer_support_agent(model, knowledge_base) do
    support_tools = [
      create_knowledge_search_tool(knowledge_base),
      create_ticket_creation_tool(),
      create_escalation_tool()
    ]
    
    Agent.create(model, %{
      system_prompt: """
      You are a helpful customer support agent. Your goal is to resolve customer 
      issues quickly and professionally. You have access to the knowledge base,
      can create support tickets, and escalate complex issues.
      
      Always be polite, empathetic, and solution-focused. If you cannot resolve
      an issue, escalate appropriately.
      """,
      tools: support_tools,
      thinking_level: :low  # Fast responses for customer support
    })
  end
end

# Usage
{:ok, model} = Expi.AI.get_model("anthropic", "claude-sonnet-3-6")

{:ok, coding_agent} = MyApp.ConversationTemplates.create_coding_assistant(model)
{:ok, research_agent} = MyApp.ConversationTemplates.create_research_assistant(model)

{:ok, coding_agent, _} = Agent.send_message(coding_agent, "Help me debug this Elixir function")
{:ok, research_agent, _} = Agent.send_message(research_agent, "Research the latest trends in AI")
```

### Error Recovery

```elixir
defmodule MyApp.ResilientAgent do
  def create_with_fallback(primary_model, fallback_model, config) do
    case Agent.create(primary_model, config) do
      {:ok, agent} ->
        {:ok, {agent, :primary, fallback_model}}
      
      error ->
        Logger.warn("Primary model failed, using fallback: #{inspect(error)}")
        case Agent.create(fallback_model, config) do
          {:ok, agent} ->
            {:ok, {agent, :fallback, nil}}
          
          fallback_error ->
            {:error, {:both_failed, error, fallback_error}}
        end
    end
  end
  
  def send_message_with_retry({agent, mode, fallback_model}, message, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 3)
    
    case attempt_send_message(agent, message, max_retries) do
      {:ok, agent, response} ->
        {:ok, {agent, mode, fallback_model}, response}
      
      {:error, reason} when mode == :primary and not is_nil(fallback_model) ->
        Logger.warn("Primary agent failed, switching to fallback: #{inspect(reason)}")
        
        case Agent.create(fallback_model, get_agent_config(agent)) do
          {:ok, fallback_agent} ->
            # Transfer conversation history
            messages = Agent.get_messages(agent)
            fallback_agent = transfer_conversation(fallback_agent, messages)
            
            case attempt_send_message(fallback_agent, message, max_retries) do
              {:ok, new_agent, response} ->
                {:ok, {new_agent, :fallback, nil}, response}
              
              error ->
                error
            end
          
          error ->
            error
        end
      
      error ->
        error
    end
  end
  
  defp attempt_send_message(agent, message, retries_left) when retries_left > 0 do
    case Agent.send_message(agent, message) do
      {:ok, agent, response} ->
        {:ok, agent, response}
      
      {:error, :rate_limited} ->
        Process.sleep(2000)
        attempt_send_message(agent, message, retries_left - 1)
      
      {:error, :network_error} ->
        Process.sleep(1000)
        attempt_send_message(agent, message, retries_left - 1)
      
      error ->
        error
    end
  end
  
  defp attempt_send_message(_agent, _message, 0) do
    {:error, :max_retries_exceeded}
  end
  
  defp get_agent_config(agent) do
    %{
      system_prompt: agent.system_prompt,
      tools: agent.tools,
      thinking_level: agent.thinking_level
    }
  end
  
  defp transfer_conversation(agent, messages) do
    Enum.reduce(messages, agent, fn message, acc ->
      case message.role do
        :user ->
          # Add user message without triggering AI response
          Agent.add_message(acc, message)
        
        :assistant ->
          Agent.add_message(acc, message)
        
        _ ->
          acc
      end
    end)
  end
end
```

## Production Considerations

### Performance Optimization

```elixir
# Agent configuration for production
production_config = %{
  # Limit conversation history to prevent memory growth
  max_context_length: 8000,
  
  # Optimize for cost vs. quality tradeoff
  temperature: 0.7,
  
  # Enable streaming for better UX
  streaming: true,
  
  # Thinking level based on use case
  thinking_level: :medium
}

{:ok, agent} = Agent.create(model, production_config)
```

### Cost Management

```elixir
defmodule MyApp.CostTracker do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def track_agent_usage(agent_stats) do
    GenServer.cast(__MODULE__, {:track_usage, agent_stats})
  end
  
  def get_daily_cost do
    GenServer.call(__MODULE__, :get_daily_cost)
  end
  
  def check_budget(user_id) do
    GenServer.call(__MODULE__, {:check_budget, user_id})
  end

  def init(opts) do
    daily_budget = Keyword.get(opts, :daily_budget, 100.0)
    user_budget = Keyword.get(opts, :user_budget, 10.0)
    
    state = %{
      daily_budget: daily_budget,
      user_budget: user_budget,
      daily_cost: 0.0,
      user_costs: %{}
    }
    {:ok, state}
  end

  def handle_cast({:track_usage, stats}, state) do
    cost = stats.total_cost
    user_id = stats.user_id
    
    new_daily_cost = state.daily_cost + cost
    new_user_cost = Map.get(state.user_costs, user_id, 0.0) + cost
    
    new_state = %{state |
      daily_cost: new_daily_cost,
      user_costs: Map.put(state.user_costs, user_id, new_user_cost)
    }
    
    # Check for budget alerts
    if new_daily_cost > state.daily_budget * 0.8 do
      Logger.warn("Daily budget 80% exceeded: $#{new_daily_cost}")
    end
    
    if new_user_cost > state.user_budget * 0.8 do
      Logger.warn("User #{user_id} budget 80% exceeded: $#{new_user_cost}")
    end
    
    {:noreply, new_state}
  end

  def handle_call(:get_daily_cost, _from, state) do
    {:reply, state.daily_cost, state}
  end

  def handle_call({:check_budget, user_id}, _from, state) do
    user_cost = Map.get(state.user_costs, user_id, 0.0)
    daily_ok = state.daily_cost < state.daily_budget
    user_ok = user_cost < state.user_budget
    
    result = %{
      daily_cost: state.daily_cost,
      daily_budget: state.daily_budget,
      user_cost: user_cost,
      user_budget: state.user_budget,
      within_budget: daily_ok and user_ok
    }
    
    {:reply, result, state}
  end
end

# Usage
{:ok, _} = MyApp.CostTracker.start_link(daily_budget: 50.0, user_budget: 5.0)

# Before expensive operations
budget_status = MyApp.CostTracker.check_budget(user_id)
if budget_status.within_budget do
  {:ok, agent, response} = Agent.send_message(agent, message)
  
  # Track usage
  stats = Agent.get_stats(agent)
  MyApp.CostTracker.track_agent_usage(Map.put(stats, :user_id, user_id))
else
  {:error, :budget_exceeded}
end
```

### Monitoring and Alerting

```elixir
# Telemetry setup for agents
:telemetry.attach_many(
  "agent-monitoring",
  [
    [:expi, :agent, :created],
    [:expi, :agent, :turn, :stop],
    [:expi, :agent, :tool, :executed]
  ],
  &MyApp.AgentTelemetry.handle_event/4,
  %{}
)

defmodule MyApp.AgentTelemetry do
  def handle_event([:expi, :agent, :created], _measurements, metadata, _config) do
    :telemetry.execute([:my_app, :agent, :created], %{count: 1}, metadata)
  end
  
  def handle_event([:expi, :agent, :turn, :stop], measurements, metadata, _config) do
    :telemetry.execute(
      [:my_app, :agent, :turn],
      %{
        duration: measurements.duration,
        messages_processed: measurements.messages_processed,
        tools_executed: measurements.tools_executed
      },
      metadata
    )
    
    # Alert on slow turns
    if measurements.duration > 30_000 do
      Logger.warn("Slow agent turn detected", %{
        duration: measurements.duration,
        agent_id: metadata.agent_id
      })
    end
  end
  
  def handle_event([:expi, :agent, :tool, :executed], measurements, metadata, _config) do
    :telemetry.execute(
      [:my_app, :agent, :tool],
      %{duration: measurements.duration},
      %{tool_name: metadata.tool_name, success: not metadata.is_error}
    )
  end
end
```

This guide provides comprehensive coverage of the Expi Agent module, from basic conversation management to advanced production patterns. The Agent module enables sophisticated AI applications with robust state management, tool integration, and event monitoring.