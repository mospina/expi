#!/usr/bin/env elixir

# Advanced ExpiAI Agent Features Demo
# 
# This script demonstrates advanced Agent module features including:
# - Message queues with steering and follow-up patterns
# - Comprehensive event monitoring
# - Agent cloning and branching
# - Turn processing with different modes
# - Advanced tool orchestration
#
# Requirements:
# - ANTHROPIC_API_KEY environment variable
#
# Usage:
#   export ANTHROPIC_API_KEY="your-key-here"
#   elixir advanced_agent_demo.exs

Mix.install([
  {:expi, path: "."},
  {:jason, "~> 1.4"}
])

defmodule AdvancedAgentDemo do
  alias Expi.Agent
  alias Expi.Agent.State
  alias Expi.AI
  alias Expi.Agent.Tool, as: AgentTool
  alias Expi.Agent.Types.AgentToolResult
  alias Expi.Types.{AssistantMessage, Context, TextContent}

  # ANSI colors
  @reset "\e[0m"
  @bold "\e[1m"
  @green "\e[32m"
  @blue "\e[34m"
  @yellow "\e[33m"
  @red "\e[31m"
  @magenta "\e[35m"
  @cyan "\e[36m"

  def run do
    IO.puts("#{@bold}#{@cyan}🚀 Advanced ExpiAI Agent Features Demo#{@reset}")
    IO.puts("#{@blue}" <> String.duplicate("=", 45) <> "#{@reset}\n")
    
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> 
        IO.puts("#{@red}❌ Please set ANTHROPIC_API_KEY environment variable#{@reset}")
        System.halt(1)
      "" -> 
        IO.puts("#{@red}❌ ANTHROPIC_API_KEY is empty#{@reset}")
        System.halt(1)
      _key ->
        run_advanced_demos()
    end
  end

  defp run_advanced_demos do
    {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
    
    # Create agent with multiple tools for comprehensive demos
    agent = create_demo_agent(model)
    
    # Run advanced feature demos
    agent = demo_message_queues(agent)
    agent = demo_event_monitoring(agent) 
    demo_agent_cloning(agent)
    demo_turn_processing_modes(agent)
    demo_comprehensive_workflow(agent)
    
    IO.puts("\n#{@bold}#{@green}🎉 Advanced demo completed!#{@reset}")
  end

  defp create_demo_agent(model) do
    tools = [
      create_research_tool(),
      create_analysis_tool(),
      create_formatting_tool()
    ]

    {:ok, agent} = Agent.create(model, %{
      system_prompt: """
      You are an advanced AI research assistant with access to research, analysis, 
      and formatting tools. You can handle complex multi-step tasks and interruptions 
      gracefully. Always explain your process and use tools appropriately.
      """,
      tools: tools
    })

    IO.puts("#{@green}✅ Created advanced agent with #{length(tools)} specialized tools#{@reset}\n")
    agent
  end

  # Demo 1: Message Queues with Steering and Follow-up
  defp demo_message_queues(agent) do
    IO.puts("#{@bold}#{@blue}🎯 Demo 1: Message Queues - Steering vs Follow-up#{@reset}")
    IO.puts("#{@blue}" <> String.duplicate("-", 48) <> "#{@reset}")

    {:ok, agent} = Agent.send_message(agent, "I need you to research machine learning trends")
    {:ok, agent} = Agent.add_follow_up(agent, "Also include information about recent breakthroughs")
    {:ok, agent} = Agent.add_follow_up(agent, "Focus specifically on transformer models")

    IO.puts("#{@yellow}📋 Added 2 follow-up messages to natural conversation flow#{@reset}")

    {:ok, agent} = Agent.add_steering(agent, "Actually, first tell me what machine learning is in simple terms")

    IO.puts("#{@magenta}🎯 Added steering message (high priority interruption)#{@reset}")
    IO.puts("\n#{@cyan}Processing conversation with event monitoring...#{@reset}")

    {:ok, agent} = Agent.run_conversation(agent, %{
      event_callback: create_queue_event_handler(),
      max_turns: 3
    })

    IO.puts("\n#{@green}✅ Queue processing completed#{@reset}")
    IO.puts("#{@cyan}🤖 Latest assistant response: #{String.slice(latest_assistant_text(agent), 0, 120)}...#{@reset}")

    agent
  end

  # Demo 2: Comprehensive Event Monitoring
  defp demo_event_monitoring(agent) do
    IO.puts("\n#{@bold}#{@blue}🎛️ Demo 2: Comprehensive Event Monitoring#{@reset}")
    IO.puts("#{@blue}" <> String.duplicate("-", 42) <> "#{@reset}")

    event_handler = create_comprehensive_event_handler()

    IO.puts("#{@yellow}🔍 Starting monitored conversation with detailed events...#{@reset}\n")

    {:ok, agent} = Agent.send_message(agent, "Analyze the benefits of functional programming and format a summary")
    {:ok, agent} = Agent.run_conversation(agent, %{event_callback: event_handler, max_turns: 2})

    IO.puts("\n#{@green}✅ Event monitoring demo completed#{@reset}")
    agent
  end

  # Demo 3: Agent Cloning and Branching
  defp demo_agent_cloning(agent) do
    IO.puts("\n#{@bold}#{@blue}🌳 Demo 3: Agent Cloning and Conversation Branching#{@reset}")
    IO.puts("#{@blue}" <> String.duplicate("-", 52) <> "#{@reset}")

    original_messages = Agent.get_messages(agent)
    IO.puts("#{@cyan}📊 Original conversation: #{length(original_messages)} messages#{@reset}")

    branch_agent_a = Agent.clone(agent)
    branch_agent_b = Agent.clone(agent)

    IO.puts("#{@yellow}🔄 Cloned agent into 2 parallel conversation branches#{@reset}")

    {:ok, branch_agent_a, response_a} = send_and_respond(branch_agent_a, "Now dive deeper into the technical implementation details")
    {:ok, branch_agent_b, response_b} = send_and_respond(branch_agent_b, "Now explain the business implications and ROI")

    messages_a = Agent.get_messages(branch_agent_a)
    messages_b = Agent.get_messages(branch_agent_b)

    IO.puts("\n#{@green}🌿 Branch A (Technical):#{@reset}")
    IO.puts("   Messages: #{length(messages_a)}")
    IO.puts("   Response: #{String.slice(response_a, 0, 80)}...")

    IO.puts("\n#{@green}🌿 Branch B (Business):#{@reset}")
    IO.puts("   Messages: #{length(messages_b)}")
    IO.puts("   Response: #{String.slice(response_b, 0, 80)}...")

    original_final = Agent.get_messages(agent)
    IO.puts("\n#{@cyan}🔍 Original conversation unchanged: #{length(original_final)} messages#{@reset}")
    IO.puts("#{@green}✅ Conversation branching successful - 3 independent timelines#{@reset}")
  end

  # Demo 4: Turn Processing Modes
  defp demo_turn_processing_modes(agent) do
    IO.puts("\n#{@bold}#{@blue}⚙️ Demo 4: Turn Processing Modes#{@reset}")
    IO.puts("#{@blue}" <> String.duplicate("-", 33) <> "#{@reset}")

    {:ok, agent} = Agent.add_follow_up(agent, "Explain design patterns")
    {:ok, agent} = Agent.add_follow_up(agent, "Give examples in Elixir")
    {:ok, agent} = Agent.add_follow_up(agent, "Compare with other languages")

    IO.puts("#{@yellow}📋 Added 3 follow-up messages#{@reset}")

    IO.puts("\n#{@cyan}🔄 Mode 1: run_conversation with follow_up_mode :all#{@reset}")
    start_time = System.monotonic_time(:millisecond)

    {:ok, agent} = Agent.run_conversation(agent, %{
      follow_up_mode: :all,
      max_turns: 3,
      event_callback: fn event ->
        case Map.get(event, :type) do
          :turn_start -> IO.puts("   🎯 Turn started")
          :turn_end -> IO.puts("   ✅ Turn completed")
          _ -> :ok
        end
      end
    })

    all_duration = System.monotonic_time(:millisecond) - start_time

    {:ok, agent} = Agent.add_follow_up(agent, "Explain design patterns")
    {:ok, agent} = Agent.add_follow_up(agent, "Give examples in Elixir")
    {:ok, agent} = Agent.add_follow_up(agent, "Compare with other languages")

    IO.puts("\n#{@cyan}🔄 Mode 2: run_conversation with follow_up_mode :one_at_a_time#{@reset}")
    start_time = System.monotonic_time(:millisecond)

    {:ok, _agent} = Agent.run_conversation(agent, %{
      follow_up_mode: :one_at_a_time,
      max_turns: 3,
      event_callback: fn event ->
        case Map.get(event, :type) do
          :message_start -> IO.puts("   📝 Message processing started")
          :message_end -> IO.puts("   ✅ Message processing completed")
          _ -> :ok
        end
      end
    })

    sequential_duration = System.monotonic_time(:millisecond) - start_time

    IO.puts("\n#{@cyan}📊 Processing Comparison:#{@reset}")
    IO.puts("   Mode :all duration: #{all_duration}ms")
    IO.puts("   Mode :one_at_a_time duration: #{sequential_duration}ms")

    efficiency = if all_duration > 0, do: round((sequential_duration / all_duration) * 100), else: 100
    IO.puts("   one_at_a_time is #{efficiency}% of :all time")
  end

  # Demo 5: Comprehensive Multi-Tool Workflow
  defp demo_comprehensive_workflow(agent) do
    IO.puts("\n#{@bold}#{@blue}🔧 Demo 5: Comprehensive Multi-Tool Workflow#{@reset}")
    IO.puts("#{@blue}" <> String.duplicate("-", 45) <> "#{@reset}")

    task = """
    I need you to:
    1. Research the topic "microservices architecture patterns"
    2. Analyze the key benefits and challenges
    3. Format a professional summary for presentation

    Please coordinate all these steps for me.
    """

    IO.puts("#{@yellow}🎯 Starting comprehensive workflow...#{@reset}\n")

    {:ok, agent} = Agent.send_message(agent, task)
    {:ok, agent} = Agent.run_conversation(agent, %{
      event_callback: create_workflow_event_handler(),
      max_turns: 3
    })

    stats = Agent.get_stats(agent)

    IO.puts("\n#{@bold}#{@green}📋 Workflow Results:#{@reset}")
    IO.puts("#{@cyan}💬 Messages processed: #{stats.message_count}#{@reset}")
    IO.puts("#{@cyan}🛠️ Tools available: #{stats.tool_count}#{@reset}")
    IO.puts("#{@cyan}🧠 Model: #{stats.provider}/#{stats.model}#{@reset}")

    IO.puts("\n#{@green}🤖 Final Response:#{@reset}")
    IO.puts(String.slice(latest_assistant_text(agent), 0, 200) <> "...")
  end

  # Tool Creation Functions
  
  defp create_research_tool do
    {:ok, tool} = AgentTool.new(
      "research_topic",
      "Research comprehensive information about a topic",
      %{
        type: :object,
        properties: %{
          topic: %{type: :string, description: "Topic to research"},
          depth: %{type: :string, enum: ["basic", "detailed", "comprehensive"], default: "detailed"}
        },
        required: ["topic"]
      },
      "Research Engine",
      fn _id, params, _signal, callback ->
        topic = params["topic"]
        depth = params["depth"] || "detailed"
        
        # Simulate research with progress updates
        if callback do
          callback.(%AgentToolResult{
            content: [],
            details: %{status: :researching, topic: topic}
          })
        end
        
        Process.sleep(800) # Simulate research time
        
        research_data = generate_research_data(topic, depth)
        
        {:ok, %AgentToolResult{
          content: [
            %TextContent{
              type: :text,
              text: """
              📚 Research Results for "#{topic}":
              
              #{research_data.summary}
              
              Key Points:
              #{Enum.join(research_data.key_points, "\n")}
              
              Sources: #{Enum.join(research_data.sources, ", ")}
              """
            }
          ],
          details: research_data
        }}
      end
    )
    tool
  end

  defp create_analysis_tool do
    {:ok, tool} = AgentTool.new(
      "analyze_content",
      "Analyze content for insights, benefits, challenges, and recommendations",
      %{
        type: :object,
        properties: %{
          content: %{type: :string, description: "Content to analyze"},
          focus: %{type: :string, description: "Analysis focus (benefits, challenges, trends, etc.)"}
        },
        required: ["content"]
      },
      "Analysis Engine",
      fn _id, params, _signal, _callback ->
        content = params["content"]
        focus = params["focus"] || "comprehensive"
        
        Process.sleep(600) # Simulate analysis time
        
        analysis = generate_analysis(content, focus)
        
        {:ok, %AgentToolResult{
          content: [
            %TextContent{
              type: :text,
              text: """
              🔍 Analysis Results (#{focus}):
              
              Benefits:
              #{Enum.join(analysis.benefits, "\n")}
              
              Challenges:
              #{Enum.join(analysis.challenges, "\n")}
              
              Recommendations:
              #{Enum.join(analysis.recommendations, "\n")}
              """
            }
          ],
          details: analysis
        }}
      end
    )
    tool
  end

  defp create_formatting_tool do
    {:ok, tool} = AgentTool.new(
      "format_content",
      "Format content for professional presentation",
      %{
        type: :object,
        properties: %{
          content: %{type: :string, description: "Content to format"},
          style: %{type: :string, enum: ["executive", "technical", "academic"], default: "professional"}
        },
        required: ["content"]
      },
      "Formatting Engine",
      fn _id, params, _signal, _callback ->
        content = params["content"]
        style = params["style"] || "professional"
        
        Process.sleep(400) # Simulate formatting time
        
        formatted = format_content(content, style)
        
        {:ok, %AgentToolResult{
          content: [
            %TextContent{
              type: :text,
              text: """
              📄 Formatted Content (#{style} style):
              
              #{formatted}
              """
            }
          ],
          details: %{original_length: String.length(content), style: style}
        }}
      end
    )
    tool
  end

  # Event Handlers

  defp create_queue_event_handler do
    fn event ->
      case Map.get(event, :type) do
        :turn_start ->
          IO.puts("   #{@magenta}🎯 Turn started - Processing message queues#{@reset}")

        :message_start ->
          role = event |> Map.get(:message, %{}) |> Map.get(:role, :unknown)
          IO.puts("   #{@cyan}📝 Processing #{role} message#{@reset}")

        :message_end ->
          IO.puts("   #{@green}✅ Message processing completed#{@reset}")

        _ -> :ok
      end
    end
  end

  defp create_comprehensive_event_handler do
    fn event ->
      case Map.get(event, :type) do
        :agent_start ->
          IO.puts("   #{@magenta}🎯 Agent started processing#{@reset}")

        :turn_start ->
          IO.puts("   #{@blue}🔄 Turn started#{@reset}")

        :tool_execution_start ->
          IO.puts("   #{@yellow}🛠️ Tool '#{Map.get(event, :tool_name)}' started#{@reset}")

        :tool_execution_end ->
          is_error = Map.get(event, :is_error, false)
          status = if is_error, do: "failed", else: "completed"
          color = if is_error, do: @red, else: @green
          IO.puts("   #{color}✅ Tool '#{Map.get(event, :tool_name)}' #{status}#{@reset}")

        :turn_end ->
          tool_results = Map.get(event, :tool_results) || []
          IO.puts("   #{@cyan}🏁 Turn completed - Tool results: #{length(tool_results)}#{@reset}")

        :agent_end ->
          IO.puts("   #{@magenta}🎌 Agent finished#{@reset}")

        _ -> :ok
      end
    end
  end

  defp create_workflow_event_handler do
    fn event ->
      case Map.get(event, :type) do
        :tool_execution_start ->
          IO.puts("   #{@yellow}🛠️ Starting #{Map.get(event, :tool_name)}...#{@reset}")

        :tool_execution_end ->
          status_icon = if Map.get(event, :is_error), do: "❌", else: "✅"
          IO.puts("   #{@green}#{status_icon} #{Map.get(event, :tool_name)}#{@reset}")

        _ -> :ok
      end
    end
  end

  # Helper Functions

  defp send_and_respond(agent, message) do
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
    |> Enum.find(fn message -> Map.get(message, :role) == :assistant end)
    |> extract_text()
  end

  defp extract_text(%{content: content}) when is_list(content) do
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
    |> Enum.join(" ")
  end

  defp extract_text(%{content: content}) when is_binary(content), do: content
  defp extract_text(nil), do: "[No assistant response]"
  defp extract_text(_), do: "[No text content]"

  defp generate_research_data(topic, depth) do
    base_points = [
      "Core concepts and definitions",
      "Current industry adoption",
      "Best practices and patterns"
    ]
    
    detailed_points = base_points ++ [
      "Implementation strategies",
      "Common pitfalls to avoid",
      "Future trends and evolution"
    ]
    
    comprehensive_points = detailed_points ++ [
      "Comparative analysis with alternatives",
      "Case studies and real-world examples",
      "Economic and business impact"
    ]
    
    key_points = case depth do
      "basic" -> Enum.take(base_points, 3)
      "detailed" -> Enum.take(detailed_points, 5) 
      "comprehensive" -> comprehensive_points
    end
    
    %{
      summary: "#{topic} is a significant area with multiple dimensions worth exploring.",
      key_points: Enum.map(key_points, &("• " <> &1)),
      sources: ["Industry Report 2024", "Technical Documentation", "Expert Interviews"],
      depth: depth
    }
  end

  defp generate_analysis(content, focus) do
    %{
      benefits: [
        "• Improved system design and architecture",
        "• Enhanced scalability and maintainability", 
        "• Better team productivity and collaboration"
      ],
      challenges: [
        "• Initial implementation complexity",
        "• Learning curve for teams",
        "• Integration with legacy systems"
      ],
      recommendations: [
        "• Start with pilot projects",
        "• Invest in team training",
        "• Establish clear governance"
      ]
    }
  end

  defp format_content(content, style) do
    case style do
      "executive" ->
        """
        ## Executive Summary
        
        #{String.slice(content, 0, 100)}...
        
        ## Key Takeaways
        - Strategic importance
        - Implementation roadmap
        - Success metrics
        """
        
      "technical" ->
        """
        # Technical Analysis
        
        #{String.slice(content, 0, 100)}...
        
        ## Implementation Details
        - Architecture patterns
        - Best practices
        - Code examples
        """
        
      _ ->
        """
        # Professional Summary
        
        #{String.slice(content, 0, 100)}...
        
        ## Overview
        - Key concepts
        - Practical applications
        - Next steps
        """
    end
  end
end

AdvancedAgentDemo.run()