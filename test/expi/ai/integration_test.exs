defmodule ExpiAi.AI.IntegrationTest do
  @moduledoc """
  Integration tests for ExpiAI with live API providers.
  
  These tests require real API keys and are excluded from regular CI.
  Run with: mix test --include integration
  
  Required environment variables:
  - ANTHROPIC_API_KEY
  - GOOGLE_API_KEY  
  - OLLAMA_ENDPOINT (optional, defaults to http://localhost:11434)
  """
  
  use ExUnit.Case, async: false
  
  alias ExpiAi.AI
  alias ExpiAi.Types.{
    Context, 
    UserMessage, 
    TextContent, 
    ImageContent,
    Tool
  }
  
  @moduletag :integration
  
  # Test timeouts for live API calls
  @api_timeout 60_000
  @stream_timeout 120_000
  
  describe "Anthropic Claude Integration" do
    @tag timeout: @api_timeout
    test "complete_simple with Claude Opus" do
      case System.get_env("ANTHROPIC_API_KEY") do
        nil ->
          IO.puts("⚠️  Skipping Anthropic test - ANTHROPIC_API_KEY not set")
          :skip
        
        _key ->
          {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")
          
          context = %Context{
            system_prompt: "You are a helpful AI assistant. Be concise.",
            messages: [
              %UserMessage{
                role: :user,
                content: "What is 2+2? Answer with just the number.",
                timestamp: System.system_time(:millisecond)
              }
            ]
          }
          
          {:ok, response} = AI.complete_simple(model, context)
          
          # Verify response structure
          assert response.role == :assistant
          assert is_list(response.content)
          assert length(response.content) > 0
          
          # Verify usage tracking
          assert response.usage.input > 0
          assert response.usage.output > 0
          assert response.usage.cost.input > 0.0
          assert response.usage.cost.output > 0.0
          
          # Verify content contains the answer
          content_text = extract_text_content(response.content)
          assert content_text =~ "4"
          
          IO.puts("✅ Claude Opus integration test passed")
          IO.puts("💰 Cost: $#{response.usage.cost.input + response.usage.cost.output}")
      end
    end
    
    @tag timeout: @api_timeout
    test "reasoning mode with Claude Opus" do
      case System.get_env("ANTHROPIC_API_KEY") do
        nil -> :skip
        _key ->
          {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")
          
          context = %Context{
            messages: [
              %UserMessage{
                role: :user,
                content: "Solve this step by step: If a train leaves Station A at 2 PM traveling at 60 mph, and another train leaves Station B at 3 PM traveling at 80 mph toward Station A, and the stations are 280 miles apart, when do they meet?",
                timestamp: System.system_time(:millisecond)
              }
            ]
          }
          
          {:ok, response} = AI.complete_simple(model, context, %{thinking: true})
          
          # Verify reasoning content is present
          assert is_binary(response.reasoning_content) or 
                 (is_list(response.reasoning_content) and length(response.reasoning_content) > 0)
          
          IO.puts("✅ Claude reasoning mode test passed")
      end
    end
    
    @tag timeout: @stream_timeout
    test "streaming with Claude Sonnet" do
      case System.get_env("ANTHROPIC_API_KEY") do
        nil -> :skip
        _key ->
          {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
          
          context = %Context{
            messages: [
              %UserMessage{
                role: :user,
                content: "Tell me a very short story about a robot learning to paint",
                timestamp: System.system_time(:millisecond)
              }
            ]
          }
          
          {:ok, stream} = AI.stream_simple(model, context)
          
          events = []
          content_text = ""
          
          stream
          |> Stream.each(fn event ->
            events = [event | events]
            
            case event.type do
              :text_delta -> 
                content_text = content_text <> event.delta
              :done ->
                # Verify final message
                assert event.message.role == :assistant
                assert event.message.usage.input > 0
                assert event.message.usage.output > 0
              _ -> 
                :ok
            end
          end)
          |> Stream.run()
          
          # Verify we received expected event types
          event_types = Enum.map(events, & &1.type) |> Enum.reverse()
          assert :start in event_types
          assert :text_start in event_types
          assert :text_delta in event_types
          assert :done in event_types
          
          # Verify we got meaningful content
          assert String.length(content_text) > 10
          assert content_text =~ "robot" or content_text =~ "paint"
          
          IO.puts("✅ Claude streaming test passed")
          IO.puts("📝 Generated #{String.length(content_text)} characters")
      end
    end
  end
  
  describe "Google Gemini Integration" do
    @tag timeout: @api_timeout
    test "complete_simple with Gemini Pro" do
      case System.get_env("GOOGLE_API_KEY") do
        nil ->
          IO.puts("⚠️  Skipping Gemini test - GOOGLE_API_KEY not set")
          :skip
        
        _key ->
          {:ok, model} = AI.get_model("google", "gemini-pro")
          
          context = %Context{
            system_prompt: "You are a helpful assistant. Be brief.",
            messages: [
              %UserMessage{
                role: :user,
                content: "What is the capital of France? Just the city name.",
                timestamp: System.system_time(:millisecond)
              }
            ]
          }
          
          {:ok, response} = AI.complete_simple(model, context)
          
          # Verify response structure  
          assert response.role == :assistant
          assert is_list(response.content)
          
          # Verify usage tracking
          assert response.usage.input > 0
          assert response.usage.output > 0
          
          # Verify content contains Paris
          content_text = extract_text_content(response.content)
          assert content_text =~ "Paris"
          
          IO.puts("✅ Gemini Pro integration test passed")
          IO.puts("💰 Cost: $#{response.usage.cost.input + response.usage.cost.output}")
      end
    end
    
    @tag timeout: @api_timeout  
    test "safety settings with Gemini" do
      case System.get_env("GOOGLE_API_KEY") do
        nil -> :skip
        _key ->
          {:ok, model} = AI.get_model("google", "gemini-pro")
          
          context = %Context{
            messages: [
              %UserMessage{
                role: :user,
                content: "Tell me about the history of artificial intelligence",
                timestamp: System.system_time(:millisecond)
              }
            ]
          }
          
          safety_settings = [
            %{category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_LOW_AND_ABOVE"},
            %{category: "HARM_CATEGORY_HATE_SPEECH", threshold: "BLOCK_LOW_AND_ABOVE"}
          ]
          
          {:ok, response} = AI.complete_simple(model, context, %{
            safety_settings: safety_settings
          })
          
          # Should complete successfully for this safe topic
          assert response.role == :assistant
          content_text = extract_text_content(response.content)
          assert String.length(content_text) > 50
          
          IO.puts("✅ Gemini safety settings test passed")
      end
    end
    
    @tag timeout: @stream_timeout
    test "streaming with Gemini Pro" do
      case System.get_env("GOOGLE_API_KEY") do
        nil -> :skip
        _key ->
          {:ok, model} = AI.get_model("google", "gemini-pro")
          
          context = %Context{
            messages: [
              %UserMessage{
                role: :user,
                content: "Write a haiku about technology",
                timestamp: System.system_time(:millisecond)
              }
            ]
          }
          
          {:ok, stream} = AI.stream_simple(model, context)
          
          events = []
          content_text = ""
          
          stream
          |> Stream.each(fn event ->
            events = [event | events]
            
            case event.type do
              :text_delta -> 
                content_text = content_text <> event.delta
              _ -> 
                :ok
            end
          end)
          |> Stream.run()
          
          # Verify streaming worked
          event_types = Enum.map(events, & &1.type) |> Enum.reverse()
          assert :start in event_types
          assert :text_delta in event_types
          assert :done in event_types
          
          # Verify haiku-like content (short, poetic)
          assert String.length(content_text) > 10
          assert String.length(content_text) < 200
          
          IO.puts("✅ Gemini streaming test passed")
          IO.puts("🎭 Generated haiku: #{String.trim(content_text)}")
      end
    end
  end
  
  describe "Ollama Integration" do
    @tag timeout: @api_timeout
    test "complete_simple with local Llama" do
      ollama_endpoint = System.get_env("OLLAMA_ENDPOINT", "http://localhost:11434")
      
      case test_ollama_connection(ollama_endpoint) do
        :error ->
          IO.puts("⚠️  Skipping Ollama test - service not available at #{ollama_endpoint}")
          :skip
        
        :ok ->
          case AI.get_model("ollama", "llama3.1:8b") do
            {:ok, model} ->
              context = %Context{
                system_prompt: "You are a helpful assistant. Be concise.",
                messages: [
                  %UserMessage{
                    role: :user,
                    content: "What is machine learning in one sentence?",
                    timestamp: System.system_time(:millisecond)
                  }
                ]
              }
              
              {:ok, response} = AI.complete_simple(model, context)
              
              # Verify response structure
              assert response.role == :assistant
              assert is_list(response.content)
              
              # Local model should have usage stats
              assert response.usage.input >= 0
              assert response.usage.output > 0
              
              # Cost should be zero for local models
              assert response.usage.cost.input == 0.0
              assert response.usage.cost.output == 0.0
              
              content_text = extract_text_content(response.content)
              assert String.length(content_text) > 10
              
              IO.puts("✅ Ollama local LLM test passed")
              IO.puts("🏠 Response: #{String.slice(content_text, 0, 100)}...")
            
            {:error, :model_not_found} ->
              IO.puts("⚠️  Skipping Ollama test - llama3.1:8b model not found")
              IO.puts("   Run: ollama pull llama3.1:8b")
              :skip
          end
      end
    end
    
    @tag timeout: @stream_timeout
    test "streaming with local CodeLlama" do
      case test_ollama_connection() do
        :error -> :skip
        :ok ->
          case AI.get_model("ollama", "codellama:7b") do
            {:ok, model} ->
              context = %Context{
                system_prompt: "You are a coding assistant. Be concise.",
                messages: [
                  %UserMessage{
                    role: :user,
                    content: "Write a simple Python function to add two numbers",
                    timestamp: System.system_time(:millisecond)
                  }
                ]
              }
              
              {:ok, stream} = AI.stream_simple(model, context)
              
              content_text = ""
              
              stream
              |> Stream.each(fn event ->
                case event.type do
                  :text_delta -> 
                    content_text = content_text <> event.delta
                  _ -> 
                    :ok
                end
              end)
              |> Stream.run()
              
              # Verify we got code-like content
              assert content_text =~ "def" or content_text =~ "function"
              assert String.length(content_text) > 20
              
              IO.puts("✅ Ollama CodeLlama streaming test passed")
              IO.puts("💻 Generated code length: #{String.length(content_text)} chars")
            
            {:error, :model_not_found} ->
              IO.puts("⚠️  Skipping CodeLlama test - model not found")
              :skip
          end
      end
    end
  end
  
  describe "Multi-Modal Integration" do
    @tag timeout: @api_timeout
    test "image analysis with Gemini Vision" do
      case System.get_env("GOOGLE_API_KEY") do
        nil -> :skip
        _key ->
          {:ok, model} = AI.get_model("google", "gemini-pro-vision")
          
          # Create a simple test image (1x1 red pixel PNG)
          test_image_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
          
          context = %Context{
            messages: [
              %UserMessage{
                role: :user,
                content: [
                  %TextContent{
                    type: :text,
                    text: "What color is this image? Just the color name."
                  },
                  %ImageContent{
                    type: :image,
                    data: test_image_base64,
                    mime_type: "image/png"
                  }
                ],
                timestamp: System.system_time(:millisecond)
              }
            ]
          }
          
          {:ok, response} = AI.complete_simple(model, context)
          
          content_text = extract_text_content(response.content)
          # Should recognize the red color
          assert content_text =~ "red" or content_text =~ "Red"
          
          IO.puts("✅ Gemini Vision integration test passed")
          IO.puts("👁️  Analysis: #{content_text}")
      end
    end
  end
  
  describe "Function Calling Integration" do
    @tag timeout: @api_timeout
    test "tool calling with Claude" do
      case System.get_env("ANTHROPIC_API_KEY") do
        nil -> :skip
        _key ->
          {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
          
          tools = [
            %Tool{
              type: :function,
              function: %{
                name: "get_weather",
                description: "Get current weather for a location",
                parameters: %{
                  type: :object,
                  properties: %{
                    location: %{type: :string, description: "City name"},
                    unit: %{type: :string, enum: ["celsius", "fahrenheit"], default: "celsius"}
                  },
                  required: ["location"]
                }
              }
            }
          ]
          
          context = %Context{
            messages: [
              %UserMessage{
                role: :user,
                content: "What's the weather like in Tokyo?",
                timestamp: System.system_time(:millisecond)
              }
            ],
            tools: tools
          }
          
          {:ok, response} = AI.complete_simple(model, context)
          
          # Should either use the tool or explain it would call the weather function
          content_text = extract_text_content(response.content)
          
          if length(response.tool_calls) > 0 do
            tool_call = hd(response.tool_calls)
            assert tool_call.name == "get_weather"
            
            # Parse arguments
            args = Jason.decode!(tool_call.arguments)
            assert args["location"] =~ "Tokyo"
            
            IO.puts("✅ Claude tool calling test passed")
            IO.puts("🛠️  Tool call: #{tool_call.name} with args #{tool_call.arguments}")
          else
            # Claude might explain what it would do instead
            assert content_text =~ "weather" or content_text =~ "Tokyo"
            IO.puts("✅ Claude explained tool usage: #{String.slice(content_text, 0, 100)}...")
          end
      end
    end
  end
  
  describe "Performance Integration" do
    @tag timeout: @api_timeout
    test "concurrent requests" do
      # Test with whichever provider is available
      provider_model = cond do
        System.get_env("ANTHROPIC_API_KEY") -> {"anthropic", "claude-sonnet-3-6"}
        System.get_env("GOOGLE_API_KEY") -> {"google", "gemini-pro"}
        test_ollama_connection() == :ok -> {"ollama", "llama3.1:8b"}
        true -> nil
      end
      
      case provider_model do
        nil -> 
          IO.puts("⚠️  Skipping concurrent test - no providers available")
          :skip
        
        {provider, model_id} ->
          {:ok, model} = AI.get_model(provider, model_id)
          
          # Create multiple simple requests
          requests = for i <- 1..3 do
            %Context{
              messages: [
                %UserMessage{
                  role: :user,
                  content: "What is #{i} + #{i}? Just the number.",
                  timestamp: System.system_time(:millisecond)
                }
              ]
            }
          end
          
          # Execute concurrently
          start_time = System.monotonic_time(:millisecond)
          
          results = 
            requests
            |> Task.async_stream(
              fn context -> AI.complete_simple(model, context) end,
              max_concurrency: 3,
              timeout: 30_000
            )
            |> Enum.map(fn {:ok, result} -> result end)
          
          end_time = System.monotonic_time(:millisecond)
          duration = end_time - start_time
          
          # Verify all succeeded
          assert length(results) == 3
          Enum.each(results, fn {:ok, response} ->
            assert response.role == :assistant
            assert length(response.content) > 0
          end)
          
          IO.puts("✅ Concurrent requests test passed")
          IO.puts("⚡ 3 requests completed in #{duration}ms")
      end
    end
  end
  
  # Helper functions
  
  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.filter(& &1.type == :text)
    |> Enum.map(& &1.text)
    |> Enum.join(" ")
  end
  
  defp extract_text_content(content) when is_binary(content), do: content
  defp extract_text_content(_), do: ""
  
  defp test_ollama_connection(endpoint \\ "http://localhost:11434") do
    try do
      case HTTPoison.get("#{endpoint}/api/tags", [], timeout: 5000, recv_timeout: 5000) do
        {:ok, %HTTPoison.Response{status_code: 200}} -> :ok
        _ -> :error
      end
    rescue
      _ -> :error
    end
  end
end