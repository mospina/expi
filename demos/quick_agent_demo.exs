#!/usr/bin/env elixir

# Quick ExpiAI Agent Demo
# 
# A simple demonstration of basic Agent capabilities.
#
# Requirements:
# - ANTHROPIC_API_KEY environment variable
#
# Usage:
#   export ANTHROPIC_API_KEY="your-key-here"  
#   elixir quick_agent_demo.exs

Mix.install([
  {:expi, path: "."},
  {:jason, "~> 1.4"}
])

defmodule QuickDemo do
  alias Expi.Agent
  alias Expi.Agent.State
  alias Expi.AI
  alias Expi.Agent.Tool, as: AgentTool
  alias Expi.Agent.Types.AgentToolResult
  alias Expi.Types.TextContent

  def run do
    IO.puts("🤖 Quick ExpiAI Agent Demo")
    IO.puts("=" |> String.duplicate(25))
    
    # Check API key
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> 
        IO.puts("❌ Please set ANTHROPIC_API_KEY environment variable")
        System.halt(1)
      "" -> 
        IO.puts("❌ ANTHROPIC_API_KEY is empty")
        System.halt(1)
      _key ->
        run_demos()
    end
  end

  defp run_demos do
    # Create agent with a simple calculator tool
    {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
    {:ok, calculator_tool} = create_calculator_tool()
    
    {:ok, agent} = Agent.create(model, %{
      system_prompt: "You are a helpful assistant with calculator abilities. Use the calculator tool for any math problems.",
      tools: [calculator_tool]
    })

    IO.puts("✅ Agent created with calculator tool\n")

    # Demo 1: Basic conversation
    IO.puts("💬 Demo 1: Basic Conversation")
    agent = send_message_and_respond(agent, "Hello! What can you help me with?")

    # Demo 2: Tool usage
    IO.puts("🧮 Demo 2: Using Calculator Tool")
    agent = send_message_and_respond(agent, "What's 15 * 23 + 45?")

    # Demo 3: Streaming response
    IO.puts("⚡ Demo 3: Streaming Response")
    IO.write("🤖: ")
    
    # Add a message for streaming
    {:ok, agent} = Agent.send_message(agent, "Give me a brief explanation of what you can do.")
    
    # Use AI.stream_simple for actual streaming
    model = agent.model
    messages = Agent.get_messages(agent)
    
    # Convert agent tools to Anthropic-compatible format
    anthropic_tools = Agent.get_tools(agent) 
    |> Enum.map(fn tool ->
      %{
        name: tool.function.name,
        description: tool.function.description,
        input_schema: tool.function.parameters
      }
    end)
    
    context = %Expi.Types.Context{
      system_prompt: agent.system_prompt,
      messages: messages,
      tools: anthropic_tools
    }
    
    case Expi.AI.stream_simple(model, context) do
      {:ok, stream} ->
        # Collect streaming content
        collected_content = []
        
        try do
          stream
          |> Enum.each(fn event ->
            case event.type do
              :text_delta -> IO.write(event.delta)
              :content_delta -> 
                if event.delta && event.delta.text do
                  IO.write(event.delta.text)
                end
              :message_done -> IO.write("\n")
              :done -> :ok
              _ -> :ok
            end
          end)
          
          IO.puts("\n✅ Streaming completed")
        rescue
          error -> 
            IO.puts("\n❌ Streaming error: #{inspect(error)}")
        end
        
        agent
        
      {:error, reason} ->
        IO.puts("❌ Streaming failed: #{inspect(reason)}\n")
        agent
    end

    # Demo 4: Conversation history
    IO.puts("\n📚 Demo 4: Conversation Summary")
    messages = Agent.get_messages(agent)
    stats = Agent.get_stats(agent)
    
    IO.puts("Messages in conversation: #{length(messages)}")
    
    # Use safe access for stats that might not exist
    case Map.get(stats, :total_cost) do
      nil -> IO.puts("Total cost: Not available")
      cost -> IO.puts("Total cost: $#{Float.round(cost, 4)}")
    end
    
    case Map.get(stats, :total_tokens) do
      nil -> IO.puts("Tokens used: Not available")
      tokens -> IO.puts("Tokens used: #{tokens}")
    end

    IO.puts("\n🎉 Quick demo completed!")
  end

  # Helper function that makes actual LLM calls using AI.complete_simple
  defp send_message_and_respond(agent, message) do
    {:ok, agent} = Agent.send_message(agent, message)
    
    # Get model and build context for direct AI call
    model = agent.model
    messages = Agent.get_messages(agent)
    
    # Convert agent tools to Anthropic-compatible format
    anthropic_tools = Agent.get_tools(agent) 
    |> Enum.map(fn tool ->
      %{
        name: tool.function.name,
        description: tool.function.description,
        input_schema: tool.function.parameters
      }
    end)
    
    context = %Expi.Types.Context{
      system_prompt: agent.system_prompt,
      messages: messages,
      tools: anthropic_tools
    }
    
    case Expi.AI.complete_simple(model, context) do
      {:ok, response} ->
        response_text = extract_text(response)
        IO.puts("🤖: #{response_text}\n")
        
        # Add the AI response back to agent conversation
        ai_message = %Expi.Types.AssistantMessage{
          role: :assistant,
          content: response.content,
          timestamp: System.system_time(:millisecond)
        }
        # Use State.add_message to properly add the assistant message
        updated_agent = State.add_message(agent, ai_message)
        updated_agent
      {:error, reason} ->
        IO.puts("🤖: [Error generating response: #{inspect(reason)}]\n")
        agent
    end
  end

  defp create_calculator_tool do
    AgentTool.new(
      "calculate",
      "Perform mathematical calculations",
      %{
        type: :object,
        properties: %{
          expression: %{type: :string, description: "Math expression to evaluate"}
        },
        required: ["expression"]
      },
      "Calculator",
      fn _id, params, _signal, _callback ->
        expression = params["expression"]
        
        try do
          {result, _} = Code.eval_string(expression)
          
          {:ok, %AgentToolResult{
            content: [%TextContent{type: :text, text: "#{expression} = #{result}"}],
            details: %{expression: expression, result: result}
          }}
        rescue
          _ -> {:error, "Invalid expression"}
        end
      end
    )
  end

  defp extract_text(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map(&(&1.text))
    |> Enum.join()
  end

  defp extract_text(%{content: content}) when is_binary(content), do: content
  defp extract_text(%{role: :assistant, content: content}), do: extract_text(%{content: content})
  defp extract_text(_), do: "[No text content]"
end

QuickDemo.run()