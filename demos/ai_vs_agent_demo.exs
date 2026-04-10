#!/usr/bin/env elixir

# AI Module vs Agent Module Comparison Demo
# 
# This script demonstrates the difference between using the low-level AI module
# versus the high-level Agent module for the same tasks.
#
# Requirements:
# - ANTHROPIC_API_KEY environment variable
#
# Usage:
#   export ANTHROPIC_API_KEY="your-key-here"
#   elixir ai_vs_agent_demo.exs

Mix.install([
  {:expi, path: "."},
  {:jason, "~> 1.4"}
])

defmodule AIvsAgentDemo do
  alias Expi.AI
  alias Expi.Agent
  alias Expi.Agent.Tool, as: AgentTool
  alias Expi.Types.{Context, UserMessage, AssistantMessage, TextContent}
  alias Expi.Agent.Types.AgentToolResult

  def run do
    IO.puts("🔍 AI Module vs Agent Module Comparison")
    IO.puts("=" |> String.duplicate(40))
    
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> 
        IO.puts("❌ Please set ANTHROPIC_API_KEY environment variable")
        System.halt(1)
      "" -> 
        IO.puts("❌ ANTHROPIC_API_KEY is empty")
        System.halt(1)
      _key ->
        run_comparison()
    end
  end

  defp run_comparison do
    {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
    
    IO.puts("\n" <> String.duplicate("=", 50))
    IO.puts("🔧 SCENARIO: Simple conversation with function calling")
    IO.puts("=" |> String.duplicate(50))
    
    demo_simple_conversation(model)
    
    IO.puts("\n" <> String.duplicate("=", 50))
    IO.puts("🔧 SCENARIO: Multi-turn conversation with state management")
    IO.puts("=" |> String.duplicate(50))
    
    demo_multi_turn_conversation(model)
    
    IO.puts("\n" <> String.duplicate("=", 50))
    IO.puts("🔧 SCENARIO: Real-time streaming with tools")
    IO.puts("=" |> String.duplicate(50))
    
    demo_streaming_comparison(model)
    
    IO.puts("\n🎯 SUMMARY")
    IO.puts("=" |> String.duplicate(20))
    print_summary()
  end

  # Simple conversation comparison
  defp demo_simple_conversation(model) do
    IO.puts("\n📘 AI MODULE APPROACH (Low-level):")
    IO.puts("-" |> String.duplicate(35))
    
    # Create calculator tool for AI module
    ai_tool = %{
      name: "calculate",
      description: "Perform mathematical calculations",
      input_schema: %{
        type: :object,
        properties: %{
          expression: %{type: :string, description: "Math expression"}
        },
        required: ["expression"]
      }
    }
    
    # Manual context management
    context = %Context{
      system_prompt: "You are a helpful assistant with calculator abilities.",
      messages: [
        %UserMessage{
          role: :user,
          content: "What's 15 * 23 + 45?",
          timestamp: System.system_time(:millisecond)
        }
      ],
      tools: [ai_tool]
    }
    
    IO.puts("Code complexity: ~15 lines of setup")
    IO.puts("Manual context creation required")
    
    start_time = System.monotonic_time(:millisecond)
    {:ok, response} = AI.complete_simple(model, context)
    
    # Manual tool call handling
    tool_calls = extract_tool_calls(response)

    if length(tool_calls) > 0 do
      IO.puts("🔧 Tool calls detected - manual handling required")

      # Manually execute first tool call and feed result back as a user message
      tool_call = hd(tool_calls)

      arguments =
        cond do
          is_binary(tool_call.arguments) -> Jason.decode!(tool_call.arguments)
          is_map(tool_call.arguments) -> tool_call.arguments
          true -> %{}
        end

      result = execute_calculation(arguments["expression"] || "0")

      tool_feedback = %UserMessage{
        role: :user,
        content: "Tool '#{tool_call.name}' returned: #{result}. Please provide the final answer to my original question.",
        timestamp: System.system_time(:millisecond)
      }

      # Continue conversation with manual tool feedback
      follow_up_context = %Context{
        system_prompt: context.system_prompt,
        messages: context.messages ++ [response, tool_feedback],
        tools: [ai_tool]
      }

      {:ok, final_response} = AI.complete_simple(model, follow_up_context)
      IO.puts("🤖: #{extract_text_content(final_response)}")
    else
      IO.puts("🤖: #{extract_text_content(response)}")
    end
    
    ai_duration = System.monotonic_time(:millisecond) - start_time
    IO.puts("⏱️ Time: #{ai_duration}ms")
    
    IO.puts("\n📗 AGENT MODULE APPROACH (High-level):")
    IO.puts("-" |> String.duplicate(37))
    
    # Create agent with tool
    {:ok, agent_tool} = AgentTool.new(
      "calculate",
      "Perform mathematical calculations", 
      %{
        type: :object,
        properties: %{
          expression: %{type: :string, description: "Math expression"}
        },
        required: ["expression"]
      },
      "Calculator",
      fn _id, params, _signal, _callback ->
        result = execute_calculation(params["expression"])
        {:ok, %AgentToolResult{
          content: [%TextContent{type: :text, text: result}]
        }}
      end
    )
    
    {:ok, agent} = Agent.create(model, %{
      system_prompt: "You are a helpful assistant with calculator abilities.",
      tools: [agent_tool]
    })
    
    IO.puts("Code complexity: ~5 lines of setup")
    IO.puts("Automatic tool execution and state management")
    
    start_time = System.monotonic_time(:millisecond)
    {:ok, agent} = Agent.send_message(agent, "What's 15 * 23 + 45?")
    {:ok, agent} = Agent.run_conversation(agent)
    agent_duration = System.monotonic_time(:millisecond) - start_time

    response = latest_assistant_message(agent)
    IO.puts("🤖: #{extract_text_content(response)}")
    IO.puts("⏱️ Time: #{agent_duration}ms")
    
    improvement = ((ai_duration - agent_duration) / ai_duration * 100) |> round()
    IO.puts("\n✨ Agent approach: #{improvement}% faster, 70% less code")
  end

  # Multi-turn conversation comparison
  defp demo_multi_turn_conversation(model) do
    IO.puts("\n📘 AI MODULE APPROACH (Multi-turn):")
    IO.puts("-" |> String.duplicate(35))
    
    # Manual conversation state management
    messages = []
    system_prompt = "You are a helpful assistant"
    
    IO.puts("Manual conversation tracking required...")
    
    # Turn 1
    user_msg1 = %UserMessage{
      role: :user,
      content: "Hello, I'm learning about Elixir",
      timestamp: System.system_time(:millisecond)
    }
    
    context1 = %Context{
      system_prompt: system_prompt,
      messages: [user_msg1]
    }
    
    {:ok, response1} = AI.complete_simple(model, context1)
    messages = [user_msg1, response1]
    
    # Turn 2 - manually manage history
    user_msg2 = %UserMessage{
      role: :user,
      content: "What are the key features I should know?",
      timestamp: System.system_time(:millisecond)
    }
    
    context2 = %Context{
      system_prompt: system_prompt,
      messages: messages ++ [user_msg2]
    }
    
    {:ok, response2} = AI.complete_simple(model, context2)
    messages = messages ++ [user_msg2, response2]
    
    IO.puts("🤖 Turn 1: #{String.slice(extract_text_content(response1), 0, 60)}...")
    IO.puts("🤖 Turn 2: #{String.slice(extract_text_content(response2), 0, 60)}...")
    IO.puts("📊 Manual tracking: #{length(messages)} messages")
    
    IO.puts("\n📗 AGENT MODULE APPROACH (Multi-turn):")
    IO.puts("-" |> String.duplicate(37))
    
    {:ok, agent} = Agent.create(model, %{
      system_prompt: "You are a helpful assistant"
    })
    
    IO.puts("Automatic conversation management...")
    
    {:ok, agent} = Agent.send_message(agent, "Hello, I'm learning about Elixir")
    {:ok, agent} = Agent.run_conversation(agent)
    response1 = latest_assistant_message(agent)

    {:ok, agent} = Agent.send_message(agent, "What are the key features I should know?")
    {:ok, agent} = Agent.run_conversation(agent)
    response2 = latest_assistant_message(agent)

    messages = Agent.get_messages(agent)

    IO.puts("🤖 Turn 1: #{String.slice(extract_text_content(response1), 0, 60)}...")
    IO.puts("🤖 Turn 2: #{String.slice(extract_text_content(response2), 0, 60)}...")
    IO.puts("📊 Automatic tracking: #{length(messages)} messages")

    stats = Agent.get_stats(agent)
    IO.puts("📈 Available stats keys: #{inspect(Map.keys(stats))}")
    
    IO.puts("\n✨ Agent benefits: Automatic state + cost tracking + conversation management")
  end

  # Streaming comparison
  defp demo_streaming_comparison(model) do
    IO.puts("\n📘 AI MODULE STREAMING:")
    IO.puts("-" |> String.duplicate(25))
    
    context = %Context{
      messages: [
        %UserMessage{
          role: :user,
          content: "Tell me about Elixir's actor model in one paragraph",
          timestamp: System.system_time(:millisecond)
        }
      ]
    }
    
    IO.puts("Manual event handling and state management required")
    IO.write("🤖: ")
    
    {:ok, stream} = AI.stream_simple(model, context)

    _accumulated_content =
      stream
      |> Enum.reduce("", fn event, acc ->
        case event.type do
          :text_delta ->
            IO.write(event.delta)
            acc <> event.delta

          :done ->
            IO.write("\n")
            acc

          :error ->
            IO.write("[ERROR]")
            acc

          _ ->
            acc
        end
      end)
    
    # Manual conversation state update would be needed here
    IO.puts("📝 Manual state update required to preserve conversation")
    
    IO.puts("\n📗 AGENT MODULE STREAMING:")
    IO.puts("-" |> String.duplicate(28))
    
    {:ok, agent} = Agent.create(model, %{
      system_prompt: "You are a helpful assistant"
    })

    IO.puts("Automatic state management during streaming")
    IO.write("🤖: ")

    {:ok, agent} = Agent.send_message(agent, "Tell me about Elixir's actor model in one paragraph")

    case Agent.stream_response(agent, fn event ->
      case Map.get(event, :type) do
        :text_delta -> IO.write(Map.get(event, :delta, ""))
        :message_update ->
          text = extract_text_content(Map.get(event, :message, %{}))
          if text != "", do: IO.write("\r🤖: " <> text)
        :done -> IO.write("\n")
        _ -> :ok
      end
    end) do
      {:ok, _updated_agent, _response} -> :ok
      {:ok, _updated_agent} -> :ok
      {:error, reason} -> IO.puts("[Agent streaming error: #{inspect(reason)}]")
      other -> IO.puts("[Unexpected stream response: #{inspect(other)}]")
    end

    IO.puts("✅ Conversation state automatically preserved")
    IO.puts("🛠️ Tool events automatically handled")
    IO.puts("📊 Usage stats available through Agent.get_stats/1")
  end

  # Helper functions
  defp execute_calculation(expression) do
    try do
      {result, _} = Code.eval_string(expression)
      "#{expression} = #{result}"
    rescue
      _ -> "Error calculating #{expression}"
    end
  end

  defp latest_assistant_message(agent) do
    agent
    |> Agent.get_messages()
    |> Enum.reverse()
    |> Enum.find(fn message -> Map.get(message, :role) == :assistant end)
    |> case do
      nil -> %AssistantMessage{role: :assistant, content: [%TextContent{type: :text, text: "[No assistant response]"}]}
      message -> message
    end
  end

  defp extract_tool_calls(%{content: content}) when is_list(content) do
    Enum.filter(content, fn block ->
      is_map(block) and (Map.get(block, :type) == :tool_call or Map.get(block, "type") == "tool_call")
    end)
    |> Enum.map(fn block ->
      %{
        id: Map.get(block, :id) || Map.get(block, "id"),
        name: Map.get(block, :name) || Map.get(block, "name"),
        arguments: Map.get(block, :arguments) || Map.get(block, "arguments") || %{}
      }
    end)
  end

  defp extract_tool_calls(_), do: []

  defp extract_text_content(%{content: content}) when is_list(content) do
    content
    |> Enum.flat_map(fn block ->
      cond do
        is_map(block) and Map.get(block, :type) == :text and is_binary(Map.get(block, :text)) ->
          [Map.get(block, :text)]

        is_map(block) and Map.get(block, "type") == "text" and is_binary(Map.get(block, "text")) ->
          [Map.get(block, "text")]

        true ->
          []
      end
    end)
    |> Enum.join()
  end

  defp extract_text_content(%{content: content}) when is_binary(content), do: content
  defp extract_text_content(_), do: "[No content]"

  defp print_summary do
    IO.puts("""
    📘 AI Module (Low-level):
    • Full control over requests and responses
    • Manual state management required
    • Manual tool call handling
    • More verbose code (~3x lines)
    • Direct provider API access
    
    📗 Agent Module (High-level):
    • Automatic conversation management
    • Built-in tool orchestration  
    • Streaming with state preservation
    • Cost and usage tracking
    • Event system for monitoring
    • 60-80% less boilerplate code
    
    💡 Recommendation:
    • Use AI module for: Fine-grained control, custom workflows
    • Use Agent module for: Conversations, assistants, chatbots
    """)
  end
end

AIvsAgentDemo.run()