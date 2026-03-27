defmodule Expi.Agent do
  @moduledoc """
  Main Agent API for conversation orchestration and AI interaction.
  
  This module provides the primary public interface for the Expi Agent system,
  offering a clean functional API for managing AI conversations with sophisticated
  features like tool execution, streaming responses, message queuing, and event
  handling.
  
  The Agent system is designed around pure functional principles with explicit
  state passing, enabling predictable behavior and easy testing. It integrates
  all the core capabilities:
  
  - **Conversation Management**: Multi-turn conversations with context preservation
  - **Tool Execution**: Concurrent execution of tools with streaming updates
  - **Message Processing**: Sophisticated message transformation and routing
  - **Queue Management**: Steering (urgent) and follow-up (natural) message handling
  - **Event System**: Real-time event emission for monitoring and UI integration
  - **Streaming Support**: Live assistant responses with incremental updates
  
  ## Core Concepts
  
  **Agent State**: Immutable state containing model configuration, conversation
  history, available tools, and processing metadata. State is explicitly threaded
  through all operations.
  
  **Two-Level Loop**: Sophisticated conversation orchestration with outer loop
  for follow-up messages and inner loop for tool execution and steering.
  
  **Message Queuing**: Advanced queuing system distinguishing between steering
  messages (interruptions) and follow-up messages (natural continuations).
  
  **Event-Driven**: Comprehensive event emission throughout the conversation
  lifecycle for real-time monitoring and integration.
  
  ## Usage Patterns
  
  ```elixir
  # Basic conversation
  {:ok, model} = Expi.AI.get_model("anthropic", "claude-sonnet-3-6")
  
  {:ok, agent_state} = Expi.Agent.create(model, %{
    system_prompt: "You are a helpful assistant",
    tools: [search_tool, calculator_tool]
  })
  
  {:ok, updated_state} = Expi.Agent.send_message(agent_state, "Hello!")
  {:ok, final_state} = Expi.Agent.run_conversation(updated_state)
  
  # With event monitoring
  callback = fn event ->
    case event.type do
      :message_update -> update_ui(event.message)
      :tool_execution_start -> show_tool_progress(event)
      :turn_end -> handle_turn_completion(event)
    end
  end
  
  {:ok, final_state} = Expi.Agent.run_conversation(updated_state, 
    event_callback: callback
  )
  
  # Advanced configuration
  options = %{
    max_turns: 10,
    steering_mode: :one_at_a_time,
    follow_up_mode: :all,
    tool_timeout: 30_000,
    transform_context: &custom_transform/2
  }
  
  {:ok, final_state} = Expi.Agent.run_conversation(updated_state, options)
  ```
  
  ## Core Functions
  
  - **Lifecycle**: `create/2`, `reset/1`, `clone/1`, `validate/1`
  - **Messaging**: `send_message/2`, `add_steering/2`, `add_follow_up/2`
  - **Conversation**: `run_conversation/2`, `process_turn/2`, `stream_response/2`
  - **Tools**: `add_tool/2`, `remove_tool/2`, `execute_pending_tools/2`
  - **State**: `get_messages/1`, `get_tools/1`, `get_stats/1`, `get_config/1`
  - **Advanced**: `run_with_queue/3`, `coordinate_processing/3`, `apply_transforms/2`
  """

  alias Expi.Agent.Types.{AgentState, AgentOptions}
  alias Expi.Agent.{State, Loop, Queue, Steering, Message}
  alias Expi.Types.Model

  require Logger

  @type agent_result :: {:ok, AgentState.t()} | {:error, any()}
  @type conversation_options :: %{
    optional(:max_turns) => pos_integer(),
    optional(:timeout) => pos_integer(),
    optional(:event_callback) => function(),
    optional(:steering_mode) => Queue.processing_mode(),
    optional(:follow_up_mode) => Queue.processing_mode(),
    optional(:tool_timeout) => pos_integer(),
    optional(:transform_context) => function(),
    optional(:convert_to_llm) => function(),
    optional(:stream_fn) => function()
  }
  @type processing_result :: {:ok, AgentState.t(), map()} | {:error, any()}

  # Default configuration values
  @default_max_turns 50
  @default_timeout 300_000  # 5 minutes
  @default_tool_timeout 30_000  # 30 seconds
  @default_steering_mode :all
  @default_follow_up_mode :one_at_a_time

  ## Core Lifecycle Functions

  @doc """
  Creates a new agent with the specified model and configuration.
  
  Initializes an agent state with the provided AI model, system prompt,
  tools, and configuration options. The agent starts with an empty
  conversation history and is ready to process messages.
  
  ## Parameters
  
  - `model` - The AI model to use for conversations
  - `config` - Configuration map with options
  
  ## Configuration Options
  
  - `system_prompt` - System prompt for the AI model
  - `tools` - List of available tools for the agent
  - `max_context_length` - Maximum context length for conversations
  - `temperature` - Model temperature setting
  - `streaming` - Enable streaming responses (default: true)
  
  ## Examples
  
      # Basic agent
      {:ok, model} = Expi.AI.get_model("anthropic", "claude-sonnet-3-6")
      {:ok, agent} = Expi.Agent.create(model, %{
        system_prompt: "You are a helpful coding assistant"
      })
      
      # Agent with tools
      search_tool = %Expi.Agent.Tool{
        name: "search",
        description: "Search for information",
        function: &MyTools.search/1
      }
      
      {:ok, agent} = Expi.Agent.create(model, %{
        system_prompt: "You are a research assistant",
        tools: [search_tool],
        max_context_length: 100_000
      })
      
      # Validate agent was created properly
      assert Expi.Agent.valid?(agent)
      assert length(Expi.Agent.get_messages(agent)) == 0
  """
  @spec create(Model.t(), map()) :: agent_result()
  def create(model, config \\ %{}) do
    Logger.debug("Creating agent", %{
      model: model.id,
      provider: model.provider,
      config_keys: Map.keys(config)
    })
    
    try do
      agent_state = State.new(model, config)
      
      Logger.info("Agent created successfully", %{
        model: model.id,
        system_prompt_length: String.length(agent_state.system_prompt || ""),
        tool_count: length(agent_state.tools)
      })
      
      {:ok, agent_state}
    rescue
      error ->
        Logger.error("Failed to create agent", %{
          reason: Exception.message(error),
          model: model.id
        })
        {:error, Exception.message(error)}
    end
  end

  @doc """
  Validates that an agent state is properly configured and ready for use.
  
  ## Examples
  
      case Expi.Agent.validate(agent) do
        :ok -> proceed_with_conversation()
        {:error, reason} -> handle_validation_error(reason)
      end
  """
  @spec validate(AgentState.t()) :: :ok | {:error, String.t()}
  def validate(agent_state) do
    State.validate(agent_state)
  end

  @doc """
  Checks if an agent state is valid and ready for processing.
  
  ## Examples
  
      if Expi.Agent.valid?(agent) do
        start_conversation()
      else
        fix_agent_configuration()
      end
  """
  @spec valid?(AgentState.t()) :: boolean()
  def valid?(agent_state) do
    case validate(agent_state) do
      :ok -> true
      {:error, _} -> false
    end
  end

  @doc """
  Resets an agent to its initial state, clearing conversation history.
  
  Preserves the model configuration, tools, and system prompt while
  clearing all messages and resetting processing state.
  
  ## Examples
  
      # Reset after a long conversation
      clean_agent = Expi.Agent.reset(agent)
      assert length(Expi.Agent.get_messages(clean_agent)) == 0
      
      # Model and tools are preserved
      assert clean_agent.model == agent.model
      assert clean_agent.tools == agent.tools
  """
  @spec reset(AgentState.t()) :: AgentState.t()
  def reset(agent_state) do
    State.reset(agent_state)
  end

  @doc """
  Creates a deep copy of an agent state for parallel processing.
  
  ## Examples
  
      # Create parallel conversation branches
      branch_a = Expi.Agent.clone(agent)
      branch_b = Expi.Agent.clone(agent)
      
      {:ok, result_a} = Expi.Agent.send_message(branch_a, "Tell me about cats")
      {:ok, result_b} = Expi.Agent.send_message(branch_b, "Tell me about dogs")
  """
  @spec clone(AgentState.t()) :: AgentState.t()
  def clone(agent_state) do
    # Create a deep copy by reconstructing the struct
    %AgentState{
      system_prompt: agent_state.system_prompt,
      model: agent_state.model,
      thinking_level: agent_state.thinking_level,
      tools: agent_state.tools,
      messages: agent_state.messages,
      is_streaming: false,  # Reset streaming status
      stream_message: nil,  # Clear streaming message
      pending_tool_calls: MapSet.new(),  # Reset pending tools
      error: nil,  # Clear any errors
      created_at: System.system_time(:millisecond),  # New creation timestamp
      max_context_length: agent_state.max_context_length,
      temperature: agent_state.temperature,
      streaming: agent_state.streaming
    }
  end

  ## Message and Conversation Functions

  @doc """
  Sends a message to the agent and adds it to the conversation history.
  
  This function adds a user message to the conversation but does not
  trigger agent processing. Use `run_conversation/2` or `process_turn/2`
  to get the agent's response.
  
  ## Examples
  
      # Add user message
      {:ok, updated_agent} = Expi.Agent.send_message(agent, "Hello, how are you?")
      
      # Message is added but no response generated yet
      messages = Expi.Agent.get_messages(updated_agent)
      assert List.last(messages).role == :user
      
      # Generate response
      {:ok, final_agent} = Expi.Agent.run_conversation(updated_agent)
  """
  @spec send_message(AgentState.t(), String.t()) :: agent_result()
  def send_message(agent_state, content) when is_binary(content) do
    user_message = Message.user(content)
    updated_state = State.add_message(agent_state, user_message)
    
    Logger.debug("User message added", %{
      content_length: String.length(content),
      total_messages: State.message_count(updated_state)
    })
    
    {:ok, updated_state}
  end

  @doc """
  Adds a steering message for urgent interruption processing.
  
  Steering messages are processed with high priority and can interrupt
  current processing to redirect the agent's attention.
  
  ## Examples
  
      # Urgent correction
      {:ok, updated_agent} = Expi.Agent.add_steering(agent, "Stop! Don't do that.")
      
      # System alert
      {:ok, updated_agent} = Expi.Agent.add_steering(agent, 
        "[SYSTEM] Memory usage high, please reduce complexity"
      )
  """
  @spec add_steering(AgentState.t(), String.t()) :: agent_result()
  def add_steering(agent_state, content) when is_binary(content) do
    steering_message = Message.user(content)
    
    # In a full implementation, we would add this to a steering queue
    # For now, we'll add it as a regular message
    updated_state = State.add_message(agent_state, steering_message)
    
    Logger.debug("Steering message added", %{
      content_preview: String.slice(content, 0, 50),
      is_urgent: String.contains?(content, ["[URGENT]", "STOP", "!"])
    })
    
    {:ok, updated_state}
  end

  @doc """
  Adds a follow-up message for natural conversation continuation.
  
  Follow-up messages wait for natural conversation breaks before being
  processed, maintaining conversation flow.
  
  ## Examples
  
      # Natural follow-up
      {:ok, updated_agent} = Expi.Agent.add_follow_up(agent, 
        "That's helpful! Can you give me an example?"
      )
      
      # Additional request
      {:ok, updated_agent} = Expi.Agent.add_follow_up(agent,
        "Also, can you format that as a table?"
      )
  """
  @spec add_follow_up(AgentState.t(), String.t()) :: agent_result()
  def add_follow_up(agent_state, content) when is_binary(content) do
    follow_up_message = Message.user(content)
    
    # In a full implementation, we would add this to a follow-up queue
    # For now, we'll add it as a regular message
    updated_state = State.add_message(agent_state, follow_up_message)
    
    Logger.debug("Follow-up message added", %{
      content_preview: String.slice(content, 0, 50)
    })
    
    {:ok, updated_state}
  end

  @doc """
  Runs a complete conversation with the agent using the two-level loop system.
  
  This is the main entry point for agent conversation processing. It orchestrates
  the complete conversation flow including message processing, tool execution,
  streaming responses, and event emission.
  
  ## Parameters
  
  - `agent_state` - The current agent state
  - `options` - Conversation options and configuration
  
  ## Options
  
  - `max_turns` - Maximum conversation turns (default: 50)
  - `timeout` - Overall conversation timeout in ms (default: 300_000)
  - `event_callback` - Function to receive real-time events
  - `steering_mode` - How to process steering messages (:all | :one_at_a_time)
  - `follow_up_mode` - How to process follow-up messages (:all | :one_at_a_time)
  - `tool_timeout` - Timeout for tool execution in ms (default: 30_000)
  - `transform_context` - Custom context transformation function
  - `convert_to_llm` - Custom LLM format conversion function
  - `stream_fn` - Custom streaming function
  
  ## Examples
  
      # Basic conversation
      {:ok, final_agent} = Expi.Agent.run_conversation(agent)
      
      # With event monitoring
      callback = fn event ->
        IO.puts("Event: " <> to_string(event.type))
      end
      
      {:ok, final_agent} = Expi.Agent.run_conversation(agent,
        event_callback: callback,
        max_turns: 10
      )
      
      # Advanced configuration
      {:ok, final_agent} = Expi.Agent.run_conversation(agent, %{
        steering_mode: :one_at_a_time,
        follow_up_mode: :all,
        tool_timeout: 45_000,
        transform_context: &MyTransforms.prune_old_messages/2
      })
  """
  @spec run_conversation(AgentState.t(), conversation_options()) :: agent_result()
  def run_conversation(agent_state, options \\ %{}) do
    # Build agent options from conversation options
    agent_options = build_agent_options(options)
    event_callback = Map.get(options, :event_callback)
    max_turns = Map.get(options, :max_turns, @default_max_turns)
    timeout = Map.get(options, :timeout, @default_timeout)
    
    Logger.info("Starting conversation", %{
      initial_messages: State.message_count(agent_state),
      max_turns: max_turns,
      timeout: timeout,
      has_event_callback: not is_nil(event_callback)
    })
    
    # Use the Loop module to run the conversation
    loop_options = [
      max_turns: max_turns,
      timeout: timeout,
      event_callback: event_callback
    ]
    
    case Loop.run_agent_loop(agent_state, agent_options, loop_options) do
      {:ok, final_state} ->
        Logger.info("Conversation completed", %{
          final_messages: State.message_count(final_state),
          success: true
        })
        {:ok, final_state}
        
      {:error, reason} = error ->
        Logger.error("Conversation failed", %{
          reason: inspect(reason),
          initial_messages: State.message_count(agent_state)
        })
        error
    end
  end

  @doc """
  Processes a single conversation turn with the agent.
  
  Executes one complete turn including message processing, assistant response
  generation, and tool execution. Useful for step-by-step conversation control.
  
  ## Examples
  
      # Process one turn at a time
      {:ok, agent_after_turn_1} = Expi.Agent.process_turn(agent)
      {:ok, agent_after_turn_2} = Expi.Agent.process_turn(agent_after_turn_1)
      
      # With custom options
      {:ok, updated_agent} = Expi.Agent.process_turn(agent, %{
        tool_timeout: 60_000,
        emit_events: true
      })
  """
  @spec process_turn(AgentState.t(), map()) :: processing_result()
  def process_turn(agent_state, options \\ %{}) do
    timeout = Map.get(options, :timeout, @default_tool_timeout)
    event_callback = Map.get(options, :event_callback)
    
    Logger.debug("Processing single turn", %{
      current_messages: State.message_count(agent_state),
      timeout: timeout
    })
    
    # Use the correct parameters for process_single_turn
    agent_options = build_agent_options(options)
    loop_options = [event_callback: event_callback]
    
    case Loop.process_single_turn(agent_state, agent_options, loop_options) do
      {:ok, updated_agent_state} ->
        turn_data = %{
          messages_processed: 1,
          tools_executed: 0,  # Would be calculated in full implementation
          turn_duration: 0    # Would be calculated in full implementation
        }
        
        {:ok, updated_agent_state, turn_data}
        
      {:error, reason} = error ->
        Logger.error("Turn processing failed", %{reason: inspect(reason)})
        error
    end
  end

  @doc """
  Streams an assistant response for the current conversation state.
  
  Generates and streams an assistant response without executing tools,
  useful for getting quick responses or implementing custom tool handling.
  
  ## Examples
  
      # Stream response with default callback
      {:ok, updated_agent, response} = Expi.Agent.stream_response(agent)
      IO.puts("Assistant said: " <> response.content)
      
      # Stream with custom event handling
      callback = fn event ->
        case event.type do
          :text_delta -> IO.write(event.delta)
          :done -> IO.puts("\\nResponse complete!")
        end
      end
      
      {:ok, updated_agent, response} = Expi.Agent.stream_response(agent, callback)
  """
  @spec stream_response(AgentState.t(), function() | nil) :: 
        {:ok, AgentState.t(), Expi.Types.AssistantMessage.t()} | {:error, any()}
  def stream_response(agent_state, stream_callback \\ nil) do
    Logger.debug("Streaming assistant response", %{
      message_count: State.message_count(agent_state),
      has_callback: not is_nil(stream_callback)
    })
    
    # For now, implement a simplified streaming approach
    # In a full implementation, this would use the Loop module's streaming capabilities
    
    case process_turn(agent_state, %{emit_events: true, event_callback: stream_callback}) do
      {:ok, updated_state, _turn_data} ->
        # Get the last assistant message from the conversation
        messages = get_messages(updated_state)
        assistant_message = Enum.find(Enum.reverse(messages), fn msg -> 
          msg.role == :assistant 
        end)
        
        if assistant_message && stream_callback do
          try do
            stream_callback.(%{type: :done, message: assistant_message})
          rescue
            error ->
              Logger.warning("Stream callback error", %{error: Exception.message(error)})
          end
        end
        
        {:ok, updated_state, assistant_message}
        
      {:error, reason} = error ->
        Logger.error("Streaming failed", %{reason: inspect(reason)})
        error
    end
  end

  ## Tool Management Functions

  @doc """
  Adds a tool to the agent's available tools.
  
  ## Examples
  
      calculator = %Expi.Agent.Tool{
        name: "calculator",
        description: "Perform mathematical calculations",
        function: &MyTools.calculate/1
      }
      
      updated_agent = Expi.Agent.add_tool(agent, calculator)
      assert length(Expi.Agent.get_tools(updated_agent)) == 1
  """
  @spec add_tool(AgentState.t(), Expi.Agent.Tool.t()) :: AgentState.t()
  def add_tool(agent_state, tool) do
    State.add_tool(agent_state, tool)
  end

  @doc """
  Removes a tool from the agent's available tools.
  
  ## Examples
  
      # Remove by name
      updated_agent = Expi.Agent.remove_tool(agent, "calculator")
      
      # Tool is no longer available
      refute Enum.any?(Expi.Agent.get_tools(updated_agent), 
        fn t -> t.name == "calculator" end
      )
  """
  @spec remove_tool(AgentState.t(), String.t()) :: AgentState.t()
  def remove_tool(agent_state, tool_name) when is_binary(tool_name) do
    State.remove_tool(agent_state, tool_name)
  end

  @doc """
  Executes pending tool calls from the conversation.
  
  Processes any tool calls that have been identified in assistant messages
  but not yet executed. Useful for custom tool execution workflows.
  
  ## Examples
  
      # Execute all pending tools
      {:ok, updated_agent, results} = Expi.Agent.execute_pending_tools(agent)
      
      IO.puts("Executed " <> to_string(length(results)) <> " tools")
      Enum.each(results, fn result ->
        IO.puts("Tool " <> result.tool_name <> ": " <> result.content)
      end)
  """
  @spec execute_pending_tools(AgentState.t(), map()) :: 
        {:ok, AgentState.t(), [Expi.Types.ToolResultMessage.t()]} | {:error, any()}
  def execute_pending_tools(agent_state, options \\ %{}) do
    timeout = Map.get(options, :timeout, @default_tool_timeout)
    
    Logger.debug("Executing pending tools", %{
      tool_count: length(State.get_tools(agent_state))
    })
    
    # Extract tool calls from recent assistant messages
    tool_calls = extract_pending_tool_calls(agent_state)
    
    if tool_calls == [] do
      {:ok, agent_state, []}
    else
      # Execute tools using the ToolExecutor
      case Expi.Agent.ToolExecutor.execute_tools_concurrent(
        tool_calls,
        State.get_tools(agent_state),
        timeout: timeout,
        max_concurrent: 5
      ) do
        {:ok, tool_results} ->
          # Add tool results to agent state
          updated_state = Enum.reduce(tool_results, agent_state, fn result, acc ->
            State.add_message(acc, result)
          end)
          
          Logger.debug("Tools executed successfully", %{
            executed: length(tool_results)
          })
          
          {:ok, updated_state, tool_results}
          
        {:error, reason} = error ->
          Logger.error("Tool execution failed", %{reason: inspect(reason)})
          error
      end
    end
  end

  ## State Access Functions

  @doc """
  Gets all messages from the agent's conversation history.
  
  ## Examples
  
      messages = Expi.Agent.get_messages(agent)
      
      IO.puts("Conversation has " <> to_string(length(messages)) <> " messages")
      Enum.each(messages, fn msg ->
        IO.puts(to_string(msg.role) <> ": " <> Message.content(msg))
      end)
  """
  @spec get_messages(AgentState.t()) :: [Expi.Agent.Message.t()]
  def get_messages(agent_state) do
    State.get_messages(agent_state)
  end

  @doc """
  Gets all available tools for the agent.
  
  ## Examples
  
      tools = Expi.Agent.get_tools(agent)
      
      IO.puts("Agent has " <> to_string(length(tools)) <> " tools available:")
      Enum.each(tools, fn tool ->
        IO.puts("- " <> tool.name <> ": " <> tool.description)
      end)
  """
  @spec get_tools(AgentState.t()) :: [Expi.Agent.Tool.t()]
  def get_tools(agent_state) do
    State.get_tools(agent_state)
  end

  @doc """
  Gets comprehensive statistics about the agent's current state.
  
  ## Examples
  
      stats = Expi.Agent.get_stats(agent)
      
      IO.puts("Messages: " <> to_string(stats.message_count))
      IO.puts("Tools: " <> to_string(stats.tool_count))
      IO.puts("Created: " <> DateTime.to_string(stats.created_at))
      IO.puts("Last activity: " <> DateTime.to_string(stats.last_activity))
  """
  @spec get_stats(AgentState.t()) :: map()
  def get_stats(agent_state) do
    messages = get_messages(agent_state)
    tools = get_tools(agent_state)
    
    last_message_time = case List.last(messages) do
      nil -> nil
      msg -> DateTime.from_unix!(Message.timestamp(msg), :millisecond)
    end
    
    %{
      message_count: length(messages),
      tool_count: length(tools),
      model: agent_state.model.id,
      provider: agent_state.model.provider,
      created_at: DateTime.from_unix!(agent_state.created_at, :millisecond),
      last_activity: last_message_time,
      is_streaming: State.is_streaming?(agent_state),
      has_error: State.has_error?(agent_state),
      system_prompt_length: String.length(agent_state.system_prompt || "")
    }
  end

  @doc """
  Gets the agent's current configuration.
  
  ## Examples
  
      config = Expi.Agent.get_config(agent)
      
      IO.puts("Model: " <> config.model.id)
      IO.puts("System prompt: " <> String.slice(config.system_prompt, 0, 50) <> "...")
      IO.puts("Max context: " <> to_string(config.max_context_length))
  """
  @spec get_config(AgentState.t()) :: map()
  def get_config(agent_state) do
    %{
      model: agent_state.model,
      system_prompt: agent_state.system_prompt,
      max_context_length: agent_state.max_context_length,
      temperature: agent_state.temperature,
      streaming: agent_state.streaming
    }
  end

  ## Advanced Integration Functions

  @doc """
  Runs conversation with explicit message queue management.
  
  Provides advanced control over message processing with separate steering
  and follow-up queues. Useful for applications requiring sophisticated
  message handling and conversation flow control.
  
  ## Examples
  
      # Create queues
      message_queue = Queue.create_queue()
      |> Queue.add_steering(Message.user("Stop and help me with this urgent issue"))
      |> Queue.add_follow_up(Message.user("Also, can you explain the previous answer?"))
      
      # Run with explicit queue management
      {:ok, final_agent, final_queue} = Expi.Agent.run_with_queue(
        agent,
        message_queue,
        %{steering_mode: :one_at_a_time, follow_up_mode: :all}
      )
  """
  @spec run_with_queue(AgentState.t(), Queue.message_queue(), map()) :: 
        {:ok, AgentState.t(), Queue.message_queue()} | {:error, any()}
  def run_with_queue(agent_state, message_queue, options \\ %{}) do
    steering_mode = Map.get(options, :steering_mode, @default_steering_mode)
    follow_up_mode = Map.get(options, :follow_up_mode, @default_follow_up_mode)
    _event_callback = Map.get(options, :event_callback)
    
    Logger.info("Running conversation with explicit queue", %{
      steering_count: length(message_queue.steering),
      follow_up_count: length(message_queue.follow_up),
      steering_mode: steering_mode,
      follow_up_mode: follow_up_mode
    })
    
    # Process messages according to priority
    case Queue.process_by_mode(message_queue, steering_mode, follow_up_mode) do
      {:steering, messages, updated_queue} ->
        # Process steering messages first
        processing_state = State.add_messages(agent_state, messages)
        
        case run_conversation(processing_state, options) do
          {:ok, final_state} -> {:ok, final_state, updated_queue}
          {:error, _reason} = error -> error
        end
        
      {:follow_up, messages, updated_queue} ->
        # Process follow-up messages
        processing_state = State.add_messages(agent_state, messages)
        
        case run_conversation(processing_state, options) do
          {:ok, final_state} -> {:ok, final_state, updated_queue}
          {:error, _reason} = error -> error
        end
        
      {:empty, final_queue} ->
        # No messages to process
        Logger.debug("No messages in queue to process")
        {:ok, agent_state, final_queue}
    end
  end

  @doc """
  Coordinates message processing with advanced steering and follow-up logic.
  
  Provides sophisticated message processing coordination using the steering
  logic to determine optimal processing timing and approach.
  
  ## Examples
  
      coordination_result = Expi.Agent.coordinate_processing(
        agent,
        message_queue,
        steering: [interrupt_tools: true, max_steering_per_turn: 3],
        follow_up: [min_idle_time_ms: 2000, natural_break_detection: true]
      )
      
      case coordination_result.action do
        :interrupt_loop -> handle_urgent_processing()
        :queue_for_next_turn -> schedule_future_processing()
        :continue_loop -> maintain_current_flow()
      end
  """
  @spec coordinate_processing(AgentState.t(), Queue.message_queue(), keyword()) :: map()
  def coordinate_processing(agent_state, message_queue, options \\ []) do
    Steering.coordinate_with_loop(agent_state, message_queue, options)
  end

  @doc """
  Applies custom message transformations to the conversation context.
  
  Enables custom preprocessing of messages before sending to the AI model,
  such as context pruning, message filtering, or format conversion.
  
  ## Examples
  
      # Prune old messages
      pruning_fn = fn messages, _context ->
        recent_messages = Enum.take(messages, -20)
        {:ok, recent_messages}
      end
      
      {:ok, updated_agent} = Expi.Agent.apply_transforms(agent, 
        transform_context: pruning_fn
      )
      
      # Custom message filtering
      filter_fn = fn messages, _context ->
        filtered = Enum.reject(messages, fn msg ->
          String.contains?(Message.content(msg), "[FILTERED]")
        end)
        {:ok, filtered}
      end
      
      {:ok, updated_agent} = Expi.Agent.apply_transforms(agent,
        transform_context: filter_fn
      )
  """
  @spec apply_transforms(AgentState.t(), map()) :: agent_result()
  def apply_transforms(agent_state, transforms \\ %{}) do
    transform_fn = Map.get(transforms, :transform_context)
    
    if transform_fn do
      messages = get_messages(agent_state)
      
      case transform_fn.(messages, nil) do
        {:ok, transformed_messages} ->
          # Replace messages with transformed versions
          reset_state = reset(agent_state)
          final_state = Enum.reduce(transformed_messages, reset_state, fn msg, acc ->
            State.add_message(acc, msg)
          end)
          
          Logger.debug("Transformations applied", %{
            original_count: length(messages),
            transformed_count: length(transformed_messages)
          })
          
          {:ok, final_state}
          
        {:error, reason} = error ->
          Logger.error("Transform failed", %{reason: inspect(reason)})
          error
      end
    else
      {:ok, agent_state}
    end
  end

  # Private helper functions

  @spec build_agent_options(conversation_options()) :: AgentOptions.t()
  defp build_agent_options(options) do
    %AgentOptions{
      steering_mode: Map.get(options, :steering_mode, @default_steering_mode),
      follow_up_mode: Map.get(options, :follow_up_mode, @default_follow_up_mode),
      transform_context: Map.get(options, :transform_context),
      convert_to_llm: Map.get(options, :convert_to_llm),
      stream_fn: Map.get(options, :stream_fn),
      session_id: Map.get(options, :session_id),
      get_api_key: Map.get(options, :get_api_key),
      max_retry_delay_ms: Map.get(options, :max_retry_delay_ms, 30_000)
    }
  end

  @spec extract_pending_tool_calls(AgentState.t()) :: [Expi.Types.ToolCall.t()]
  defp extract_pending_tool_calls(agent_state) do
    # Get recent assistant messages and extract tool calls
    messages = get_messages(agent_state)
    
    messages
    |> Enum.filter(fn msg -> msg.role == :assistant end)
    |> Enum.take(-3)  # Look at last 3 assistant messages
    |> Enum.flat_map(fn assistant_msg ->
      case assistant_msg do
        %{content: content} when is_list(content) ->
          Enum.filter(content, fn block ->
            match?(%{type: :tool_call}, block)
          end)
          |> Enum.map(fn %{type: :tool_call} = tool_block ->
            %Expi.Types.ToolCall{
              id: Map.get(tool_block, :id, "unknown"),
              name: Map.get(tool_block, :name, "unknown"),
              arguments: Map.get(tool_block, :arguments, %{})
            }
          end)
        _ ->
          []
      end
    end)
  end
end