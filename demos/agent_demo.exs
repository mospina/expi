#!/usr/bin/env elixir

# ExpiAI Agent Module Demo
# 
# This script demonstrates the comprehensive capabilities of the ExpiAI Agent module
# including conversation management, tool integration, streaming, and event monitoring.
#
# Requirements:
# - ANTHROPIC_API_KEY environment variable
# - mix deps.get (to install dependencies)
#
# Usage:
#   export ANTHROPIC_API_KEY="your-key-here"
#   elixir agent_demo.exs

Mix.install([
  {:expi, path: "."},
  {:jason, "~> 1.4"},
  {:req, "~> 0.4"}
])

defmodule AgentDemo do
  @moduledoc """
  Comprehensive demo of ExpiAI Agent module capabilities.
  """
  
  alias Expi.Agent
  alias Expi.Agent.State
  alias Expi.AI
  alias Expi.Agent.Tool, as: AgentTool
  alias Expi.Agent.Types.AgentToolResult
  alias Expi.Types.{AssistantMessage, Context, TextContent}
  
  # ANSI colors for pretty output
  @green "\e[32m"
  @blue "\e[34m"
  @yellow "\e[33m"
  @red "\e[31m"
  @magenta "\e[35m"
  @cyan "\e[36m"
  @reset "\e[0m"
  @bold "\e[1m"

  # Public color helpers (used by EventMonitor/EnhancedAgentDemo)
  def color(:green), do: @green
  def color(:blue), do: @blue
  def color(:yellow), do: @yellow
  def color(:red), do: @red
  def color(:magenta), do: @magenta
  def color(:cyan), do: @cyan
  def color(:reset), do: @reset
  def color(:bold), do: @bold
  
  def run do
    IO.puts("#{@bold}#{@cyan}🤖 ExpiAI Agent Module Demo#{@reset}")
    IO.puts("#{@blue}=====================================#{@reset}\n")
    
    case check_prerequisites() do
      :ok ->
        run_demo()
      {:error, reason} ->
        IO.puts("#{@red}❌ Prerequisites not met: #{reason}#{@reset}")
        System.halt(1)
    end
  end
  
  defp check_prerequisites do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil ->
        {:error, "ANTHROPIC_API_KEY environment variable not set"}
      "" ->
        {:error, "ANTHROPIC_API_KEY environment variable is empty"}
      _key ->
        :ok
    end
  end
  
  defp run_demo do
    IO.puts("#{@yellow}🔧 Creating agent with tools...#{@reset}")
    
    # Create an agent with multiple tools
    {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
    
    tools = [
      create_calculator_tool(),
      create_weather_tool(), 
      create_code_analyzer_tool(),
      create_web_search_tool()
    ]
    
    {:ok, agent} = Agent.create(model, %{
      system_prompt: """
      You are a helpful AI assistant with access to several tools:
      - Calculator for mathematical operations
      - Weather checker for location-based weather info
      - Code analyzer for examining and explaining code
      - Web search for finding current information
      
      You should use these tools when appropriate to provide accurate, helpful responses.
      Always explain what you're doing when using tools.
      """,
      tools: tools
    })
    
    IO.puts("#{@green}✅ Agent created with #{length(tools)} tools#{@reset}\n")
    
    # Demo different agent capabilities
    agent = demo_basic_conversation(agent)
    agent = demo_calculator_tool(agent)
    agent = demo_weather_tool(agent)
    agent = demo_code_analysis(agent)
    agent = demo_web_search(agent)
    agent = demo_streaming_response(agent)
    agent = demo_multi_tool_usage(agent)
    demo_conversation_history(agent)
    demo_agent_statistics(agent)
    
    IO.puts("\n#{@bold}#{@green}🎉 Demo completed successfully!#{@reset}")
    IO.puts("#{@blue}The Agent module provides powerful conversation orchestration with:#{@reset}")
    IO.puts("  • Automatic state management")
    IO.puts("  • Concurrent tool execution") 
    IO.puts("  • Real-time streaming")
    IO.puts("  • Comprehensive event monitoring")
    IO.puts("  • Cost tracking and analytics")
  end
  
  # Tool Creation Functions
  
  def create_calculator_tool do
    {:ok, tool} = AgentTool.new(
      "calculate",
      "Perform mathematical calculations and evaluate expressions",
      %{
        type: :object,
        properties: %{
          expression: %{
            type: :string,
            description: "Mathematical expression to evaluate (e.g., '2 + 2', '(10 * 5) / 2')"
          }
        },
        required: ["expression"]
      },
      "Calculator",
      &execute_calculator/4
    )
    tool
  end
  
  defp execute_calculator(_tool_call_id, params, _abort_signal, _update_callback) do
    expression = params["expression"]
    
    try do
      # Simple expression evaluator (production would use a proper math parser)
      result = case Code.eval_string(expression) do
        {value, _} when is_number(value) -> value
        _ -> :error
      end
      
      if result == :error do
        {:error, "Invalid mathematical expression"}
      else
        {:ok, %AgentToolResult{
          content: [
            %TextContent{
              type: :text,
              text: "#{expression} = #{result}"
            }
          ],
          details: %{
            expression: expression,
            result: result,
            calculated_at: DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }}
      end
    rescue
      _ ->
        {:error, "Failed to evaluate mathematical expression"}
    end
  end
  
  defp create_weather_tool do
    {:ok, tool} = AgentTool.new(
      "get_weather",
      "Get current weather information for any city",
      %{
        type: :object,
        properties: %{
          city: %{
            type: :string,
            description: "Name of the city to get weather for"
          },
          units: %{
            type: :string,
            enum: ["celsius", "fahrenheit"],
            description: "Temperature units (defaults to celsius)"
          }
        },
        required: ["city"]
      },
      "Weather Service",
      &execute_weather/4
    )
    tool
  end
  
  defp execute_weather(_tool_call_id, params, _abort_signal, update_callback) do
    city = params["city"]
    units = params["units"] || "celsius"
    
    # Simulate API call with progress update
    if update_callback do
      update_callback.(%AgentToolResult{
        content: [],
        details: %{status: :fetching, city: city}
      })
    end
    
    # Simulate network delay
    Process.sleep(1000)
    
    # Mock weather data (production would call a real weather API)
    weather_data = %{
      city: city,
      temperature: if(units == "celsius", do: 22, else: 72),
      condition: Enum.random(["sunny", "cloudy", "partly cloudy", "rainy"]),
      humidity: Enum.random(30..80),
      units: units
    }
    
    {:ok, %AgentToolResult{
      content: [
        %TextContent{
          type: :text,
          text: """
          🌤️ Weather in #{weather_data.city}:
          Temperature: #{weather_data.temperature}°#{if units == "celsius", do: "C", else: "F"}
          Condition: #{weather_data.condition}
          Humidity: #{weather_data.humidity}%
          """
        }
      ],
      details: weather_data
    }}
  end
  
  defp create_code_analyzer_tool do
    {:ok, tool} = AgentTool.new(
      "analyze_code",
      "Analyze code snippets for quality, potential issues, and suggestions",
      %{
        type: :object,
        properties: %{
          code: %{
            type: :string,
            description: "Code snippet to analyze"
          },
          language: %{
            type: :string,
            description: "Programming language (e.g., elixir, python, javascript)"
          }
        },
        required: ["code"]
      },
      "Code Analyzer",
      &execute_code_analyzer/4
    )
    tool
  end
  
  defp execute_code_analyzer(_tool_call_id, params, _abort_signal, _update_callback) do
    code = params["code"]
    language = params["language"] || "unknown"
    
    # Simple code analysis (production would use proper static analysis)
    analysis = %{
      lines: length(String.split(code, "\n")),
      characters: String.length(code),
      language: language,
      suggestions: generate_code_suggestions(code, language)
    }
    
    {:ok, %AgentToolResult{
      content: [
        %TextContent{
          type: :text,
          text: """
          📊 Code Analysis Results:
          Language: #{analysis.language}
          Lines of code: #{analysis.lines}
          Characters: #{analysis.characters}
          
          Suggestions:
          #{Enum.join(analysis.suggestions, "\n")}
          """
        }
      ],
      details: analysis
    }}
  end
  
  defp generate_code_suggestions(code, language) do
    suggestions = []
    
    suggestions = if String.contains?(code, "TODO") or String.contains?(code, "FIXME") do
      ["• Consider addressing TODO/FIXME comments" | suggestions]
    else
      suggestions
    end
    
    suggestions = if language == "elixir" and String.contains?(code, "def ") do
      ["• Good use of Elixir function definitions" | suggestions]
    else
      suggestions
    end
    
    suggestions = if String.length(code) > 1000 do
      ["• Consider breaking large code blocks into smaller functions" | suggestions]
    else
      suggestions
    end
    
    case suggestions do
      [] -> ["• Code looks good! No immediate suggestions."]
      _ -> suggestions
    end
  end
  
  defp create_web_search_tool do
    {:ok, tool} = AgentTool.new(
      "search_web", 
      "Search the web for current information on any topic",
      %{
        type: :object,
        properties: %{
          query: %{
            type: :string,
            description: "Search query to find information about"
          },
          max_results: %{
            type: :integer,
            minimum: 1,
            maximum: 10,
            description: "Maximum number of results to return (default: 5)"
          }
        },
        required: ["query"]
      },
      "Web Search",
      &execute_web_search/4
    )
    tool
  end
  
  defp execute_web_search(_tool_call_id, params, _abort_signal, _update_callback) do
    query = params["query"]
    max_results = params["max_results"] || 5
    
    # Mock search results (production would use a real search API)
    results = generate_mock_search_results(query, max_results)
    
    result_text = 
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {result, index} ->
        "#{index}. #{result.title}\n   #{result.url}\n   #{result.snippet}"
      end)
      |> Enum.join("\n\n")
    
    {:ok, %AgentToolResult{
      content: [
        %TextContent{
          type: :text,
          text: """
          🔍 Web Search Results for "#{query}":
          
          #{result_text}
          """
        }
      ],
      details: %{
        query: query,
        results_count: length(results),
        results: results
      }
    }}
  end
  
  defp generate_mock_search_results(query, max_results) do
    base_results = [
      %{
        title: "#{query} - Overview",
        url: "https://example.com/#{String.replace(query, " ", "-")}",
        snippet: "Comprehensive information about #{query} including definitions, examples, and best practices."
      },
      %{
        title: "Latest #{query} News",
        url: "https://news.example.com/#{String.replace(query, " ", "-")}",
        snippet: "Recent developments and updates related to #{query} from trusted news sources."
      },
      %{
        title: "#{query} Tutorial",
        url: "https://tutorial.example.com/#{String.replace(query, " ", "-")}",
        snippet: "Step-by-step guide and tutorial for understanding and working with #{query}."
      },
      %{
        title: "#{query} Documentation",
        url: "https://docs.example.com/#{String.replace(query, " ", "-")}",
        snippet: "Official documentation and reference materials for #{query}."
      },
      %{
        title: "#{query} Community Discussion",
        url: "https://forum.example.com/#{String.replace(query, " ", "-")}",
        snippet: "Community discussions, questions, and answers about #{query}."
      }
    ]
    
    Enum.take(base_results, max_results)
  end
  
  # Demo Functions
  
  defp demo_basic_conversation(agent) do
    IO.puts("#{@bold}#{@blue}💬 Demo 1: Basic Conversation#{@reset}")

    case send_and_process(agent, "Hello! What can you help me with?") do
      {:ok, agent, response_text} ->
        IO.puts("#{@green}🤖 Assistant:#{@reset} #{response_text}")
        IO.puts("")
        agent

      {:error, reason} ->
        IO.puts("#{@red}❌ Error:#{@reset} #{inspect(reason)}")
        IO.puts("")
        agent
    end
  end

  defp demo_calculator_tool(agent) do
    IO.puts("#{@bold}#{@blue}🧮 Demo 2: Calculator Tool#{@reset}")

    case send_and_process(agent, "Can you calculate (15 * 23) + 45 - 12?") do
      {:ok, agent, response_text} ->
        IO.puts("#{@green}🤖 Assistant:#{@reset} #{response_text}")
        IO.puts("")
        agent

      {:error, reason} ->
        IO.puts("#{@red}❌ Error:#{@reset} #{inspect(reason)}")
        IO.puts("")
        agent
    end
  end

  defp demo_weather_tool(agent) do
    IO.puts("#{@bold}#{@blue}🌤️ Demo 3: Weather Tool#{@reset}")

    case send_and_process(agent, "What's the weather like in Tokyo?") do
      {:ok, agent, response_text} ->
        IO.puts("#{@green}🤖 Assistant:#{@reset} #{response_text}")
        IO.puts("")
        agent

      {:error, reason} ->
        IO.puts("#{@red}❌ Error:#{@reset} #{inspect(reason)}")
        IO.puts("")
        agent
    end
  end

  defp demo_code_analysis(agent) do
    IO.puts("#{@bold}#{@blue}📊 Demo 4: Code Analysis Tool#{@reset}")

    code_sample = """
    def fibonacci(n) when n <= 1, do: n
    def fibonacci(n), do: fibonacci(n - 1) + fibonacci(n - 2)

    # TODO: Optimize with memoization
    """

    message = "Can you analyze this Elixir code for me?\n\n```elixir\n#{code_sample}\n```"

    case send_and_process(agent, message) do
      {:ok, agent, response_text} ->
        IO.puts("#{@green}🤖 Assistant:#{@reset} #{response_text}")
        IO.puts("")
        agent

      {:error, reason} ->
        IO.puts("#{@red}❌ Error:#{@reset} #{inspect(reason)}")
        IO.puts("")
        agent
    end
  end

  defp demo_web_search(agent) do
    IO.puts("#{@bold}#{@blue}🔍 Demo 5: Web Search Tool#{@reset}")

    case send_and_process(agent, "Search for information about 'Elixir programming language'") do
      {:ok, agent, response_text} ->
        IO.puts("#{@green}🤖 Assistant:#{@reset} #{response_text}")
        IO.puts("")
        agent

      {:error, reason} ->
        IO.puts("#{@red}❌ Error:#{@reset} #{inspect(reason)}")
        IO.puts("")
        agent
    end
  end

  defp demo_streaming_response(agent) do
    IO.puts("#{@bold}#{@blue}⚡ Demo 6: Real-time Streaming#{@reset}")

    {:ok, agent} = Agent.send_message(agent, "Briefly summarize what tools you can use and when.")

    IO.write("#{@green}🤖 Assistant (streaming):#{@reset} ")

    context = build_context(agent)

    case AI.stream_simple(agent.model, context) do
      {:ok, stream} ->
        streamed_text =
          stream
          |> Enum.reduce("", fn event, acc ->
            case event.type do
              :text_delta ->
                IO.write(event.delta)
                acc <> event.delta

              :content_delta ->
                delta_text = if event.delta && event.delta.text, do: event.delta.text, else: ""
                if delta_text != "", do: IO.write(delta_text)
                acc <> delta_text

              :message_done ->
                acc

              :done ->
                acc

              _ ->
                acc
            end
          end)

        IO.puts("")

        if String.trim(streamed_text) != "" do
          assistant_message = %AssistantMessage{
            role: :assistant,
            content: [%TextContent{type: :text, text: streamed_text}],
            timestamp: System.system_time(:millisecond)
          }

          agent = State.add_message(agent, assistant_message)
          IO.puts("")
          agent
        else
          IO.puts("#{@yellow}[No streaming text received]#{@reset}\n")
          agent
        end

      {:error, reason} ->
        IO.puts("#{@red}❌ Streaming failed: #{inspect(reason)}#{@reset}\n")
        agent
    end
  end

  defp demo_multi_tool_usage(agent) do
    IO.puts("#{@bold}#{@blue}🛠️ Demo 7: Multi-Tool Usage#{@reset}")

    message = """
    I need you to:
    1. Calculate how much I'd save if I get a 15% discount on a $240 purchase
    2. Check the weather in Paris
    3. Search for information about 'machine learning trends 2024'

    Can you help with all of these?
    """

    case send_and_process(agent, message) do
      {:ok, agent, response_text} ->
        IO.puts("#{@green}🤖 Assistant:#{@reset} #{response_text}")
        IO.puts("")
        agent

      {:error, reason} ->
        IO.puts("#{@red}❌ Error:#{@reset} #{inspect(reason)}")
        IO.puts("")
        agent
    end
  end
  
  defp demo_conversation_history(agent) do
    IO.puts("#{@bold}#{@blue}📚 Demo 8: Conversation History#{@reset}")
    
    messages = Agent.get_messages(agent)
    
    IO.puts("#{@cyan}📊 Conversation Summary:#{@reset}")
    IO.puts("  • Total messages: #{length(messages)}")
    
    user_messages = Enum.count(messages, &(&1.role == :user))
    assistant_messages = Enum.count(messages, &(&1.role == :assistant))
    
    IO.puts("  • User messages: #{user_messages}")
    IO.puts("  • Assistant messages: #{assistant_messages}")
    IO.puts("")
    
    # Show recent conversation
    IO.puts("#{@cyan}💬 Recent Conversation:#{@reset}")
    messages
    |> Enum.take(-6)  # Last 6 messages
    |> Enum.each(fn message ->
      role_color = if message.role == :user, do: @blue, else: @green
      role_icon = if message.role == :user, do: "👤", else: "🤖"
      role_text = String.capitalize(to_string(message.role))
      
      content = extract_content(message)
      truncated_content = if String.length(content) > 100 do
        String.slice(content, 0, 100) <> "..."
      else
        content
      end
      
      IO.puts("  #{role_color}#{role_icon} #{role_text}:#{@reset} #{truncated_content}")
    end)
    
    IO.puts("")
  end
  
  defp demo_agent_statistics(agent) do
    IO.puts("#{@bold}#{@blue}📈 Demo 9: Agent Statistics#{@reset}")

    stats = Agent.get_stats(agent)
    config = Agent.get_config(agent)
    tools = Agent.get_tools(agent)

    IO.puts("#{@cyan}🤖 Agent Configuration:#{@reset}")
    IO.puts("  • Model: #{config.model.provider}/#{config.model.id}")
    IO.puts("  • System Prompt: #{String.slice(config.system_prompt, 0, 50)}...")
    IO.puts("  • Available Tools: #{length(tools)}")

    IO.puts("\n#{@cyan}📊 Usage Statistics:#{@reset}")
    IO.puts("  • Messages Processed: #{stats.message_count}")
    IO.puts("  • Tools Available: #{stats.tool_count}")
    IO.puts("  • Last Activity: #{format_timestamp(stats.last_activity)}")
    IO.puts("  • Created: #{format_timestamp(stats.created_at)}")

    IO.puts("\n#{@cyan}🛠️ Available Tools:#{@reset}")
    tools
    |> Enum.each(fn tool ->
      IO.puts("  • #{tool.function.name}: #{tool.function.description}")
    end)

    IO.puts("")
  end

  # Helper Functions

  defp send_and_process(agent, message) do
    with {:ok, agent} <- Agent.send_message(agent, message),
         {:ok, response} <- AI.complete_simple(agent.model, build_context(agent)) do
      assistant_message = %AssistantMessage{
        role: :assistant,
        content: response.content,
        timestamp: System.system_time(:millisecond)
      }

      updated_agent = State.add_message(agent, assistant_message)
      {:ok, updated_agent, latest_assistant_text(updated_agent)}
    end
  end

  defp build_context(agent) do
    %Context{
      system_prompt: agent.system_prompt,
      messages: Agent.get_messages(agent),
      tools: to_provider_tools(Agent.get_tools(agent))
    }
  end

  defp to_provider_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        name: tool.function.name,
        description: tool.function.description,
        input_schema: tool.function.parameters
      }
    end)
  end

  defp latest_assistant_text(agent) do
    agent
    |> Agent.get_messages()
    |> Enum.reverse()
    |> Enum.find(fn message -> message.role == :assistant end)
    |> case do
      nil -> "[No assistant response]"
      message ->
        text = extract_content(message)
        if String.trim(text) == "", do: "[Assistant response had no text content]", else: text
    end
  end

  defp extract_content(%{content: content}) when is_list(content) do
    content
    |> Enum.flat_map(fn block ->
      cond do
        is_map(block) and Map.get(block, :type) == :text and is_binary(Map.get(block, :text)) ->
          [Map.get(block, :text)]

        is_map(block) and Map.get(block, :type) == "text" and is_binary(Map.get(block, :text)) ->
          [Map.get(block, :text)]

        is_map(block) and Map.get(block, "type") == "text" and is_binary(Map.get(block, "text")) ->
          [Map.get(block, "text")]

        is_map(block) and Map.get(block, :type) in [:tool_call, "tool_call"] ->
          tool_name = Map.get(block, :name) || Map.get(block, "name") || "unknown_tool"
          ["[Tool requested: #{tool_name}]"]

        true ->
          []
      end
    end)
    |> Enum.join(" ")
  end

  defp extract_content(%{content: content}) when is_binary(content), do: content

  defp extract_content(_), do: ""

  defp format_timestamp(nil), do: "N/A"
  defp format_timestamp(%DateTime{} = timestamp), do: DateTime.to_string(timestamp)

  defp format_timestamp(timestamp) when is_integer(timestamp) do
    timestamp
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_string()
  end

  defp format_timestamp(_), do: "N/A"
end

# Event monitoring demo
defmodule EventMonitor do
  def create_event_handler do
    fn event ->
      case Map.get(event, :type) do
        :agent_start ->
          IO.puts("#{AgentDemo.color(:magenta)}🎯 Agent started processing#{AgentDemo.color(:reset)}")

        :turn_start ->
          IO.puts("#{AgentDemo.color(:blue)}🔄 Turn started#{AgentDemo.color(:reset)}")

        :tool_execution_start ->
          IO.puts("#{AgentDemo.color(:yellow)}🛠️ Tool started: #{Map.get(event, :tool_name)}#{AgentDemo.color(:reset)}")

        :tool_execution_end ->
          status = if Map.get(event, :is_error), do: "failed", else: "completed"
          IO.puts("#{AgentDemo.color(:green)}✅ Tool #{Map.get(event, :tool_name)} #{status}#{AgentDemo.color(:reset)}")

        :turn_end ->
          tool_results = Map.get(event, :tool_results) || []
          IO.puts("#{AgentDemo.color(:cyan)}🏁 Turn completed - Tool results: #{length(tool_results)}#{AgentDemo.color(:reset)}")

        :agent_end ->
          IO.puts("#{AgentDemo.color(:magenta)}🎌 Agent finished#{AgentDemo.color(:reset)}")

        _ ->
          :ok
      end
    end
  end
end


# Enhanced demo with event monitoring
defmodule EnhancedAgentDemo do
  def run_with_events do
    IO.puts("\n#{AgentDemo.color(:bold)}#{AgentDemo.color(:cyan)}🎛️ Enhanced Demo: Agent with Event Monitoring#{AgentDemo.color(:reset)}")
    IO.puts("#{AgentDemo.color(:blue)}===============================================#{AgentDemo.color(:reset)}\n")
    
    alias Expi.Agent
    alias Expi.AI
    
    {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
    {:ok, agent} = Agent.create(model, %{
      system_prompt: "You are a helpful assistant with calculation abilities"
    })
    
    # Add calculator tool
    calculator = AgentDemo.create_calculator_tool()
    agent = Agent.add_tool(agent, calculator)
    
    event_handler = EventMonitor.create_event_handler()
    
    IO.puts("#{AgentDemo.color(:yellow)}🔍 Monitoring agent events during conversation...#{AgentDemo.color(:reset)}\n")

    {:ok, agent} = Agent.send_message(agent, "Please calculate 12 * 12 and explain the result briefly.")

    {:ok, _agent, _turn_data} = Agent.process_turn(agent, %{
      event_callback: event_handler
    })
    
    IO.puts("\n#{AgentDemo.color(:green)}✅ Event monitoring demo completed#{AgentDemo.color(:reset)}")
  end
end

# Main execution
IO.puts("Starting ExpiAI Agent Demo...")

try do
  AgentDemo.run()
  EnhancedAgentDemo.run_with_events()
rescue
  error ->
    IO.puts("#{AgentDemo.color(:red)}❌ Demo failed: #{Exception.message(error)}#{AgentDemo.color(:reset)}")
    IO.puts("#{AgentDemo.color(:yellow)}💡 Make sure you have set ANTHROPIC_API_KEY environment variable#{AgentDemo.color(:reset)}")
    System.halt(1)
end