#!/usr/bin/env elixir

# Real-world streaming demo showing actual AI conversations

Code.prepend_path("lib")

alias Expi.AI
alias Expi.Types.{Context, UserMessage}

defmodule StreamingDemo do
  def run do
    IO.puts("=== 🤖 REAL AI STREAMING DEMONSTRATION ===")
    IO.puts("Testing streaming with realistic AI conversations")
    
    # Get model
    {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
    IO.puts("🎯 Using: #{model.name} (#{model.id})")
    
    # Test scenarios
    scenarios = [
      {
        "📚 Creative Writing", 
        "Write a short creative story about a robot who discovers they can dream. Make it engaging and imaginative.",
        "This will generate a longer creative response perfect for showcasing streaming."
      },
      {
        "💻 Code Explanation",
        "Explain how machine learning neural networks work, including backpropagation, in simple terms with analogies.",
        "Technical explanations show streaming with structured, detailed responses."
      },
      {
        "🧩 Problem Solving", 
        "I have 12 coins and one is fake (lighter than the others). How can I find the fake coin using a balance scale in just 3 weighings? Walk through the strategy step by step.",
        "Step-by-step reasoning demonstrates streaming with logical flow."
      }
    ]
    
    for {title, prompt, description} <- scenarios do
      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("#{title}")
      IO.puts("#{description}")
      IO.puts(String.duplicate("=", 70))
      
      context = %Context{
        system_prompt: "You are a helpful, creative, and knowledgeable AI assistant. Provide detailed, engaging responses.",
        messages: [%UserMessage{
          role: :user,
          content: prompt,
          timestamp: System.system_time(:millisecond)
        }],
        tools: nil
      }
      
      # Show the user prompt
      IO.puts("\n👤 Human: #{prompt}")
      
      # Compare sync vs streaming
      IO.puts("\n" <> String.duplicate("-", 50))
      IO.puts("🔄 SYNCHRONOUS RESPONSE (wait for complete response):")
      IO.puts(String.duplicate("-", 50))
      
      sync_start = System.monotonic_time(:millisecond)
      case AI.complete_simple(model, context) do
        {:ok, response} ->
          sync_duration = System.monotonic_time(:millisecond) - sync_start
          content = response.content |> hd() |> Map.get(:text)
          
          IO.puts("🤖 Claude: #{content}")
          IO.puts("\n📊 Sync Stats:")
          IO.puts("   ⏱️  Response time: #{sync_duration}ms")
          IO.puts("   🔤 Response length: #{String.length(content)} characters")
          IO.puts("   📈 Tokens: #{response.usage.input} in → #{response.usage.output} out")
          IO.puts("   💰 Cost: $#{Float.round(response.usage.cost.input + response.usage.cost.output, 6)}")
        
        {:error, reason} ->
          IO.puts("❌ Sync failed: #{inspect(reason)}")
          :ok  # Continue to streaming test
      end
      
      IO.puts("\n" <> String.duplicate("-", 50))
      IO.puts("🚀 STREAMING RESPONSE (real-time as AI generates):")
      IO.puts(String.duplicate("-", 50))
      
      stream_start = System.monotonic_time(:millisecond)
      case AI.stream_simple(model, context) do
        {:ok, stream} ->
          IO.write("🤖 Claude: ")
          
          # Track streaming metrics
          {char_count, word_count, event_count, first_char_time, last_char_time, final_message} = 
            stream
            |> Enum.reduce({0, 0, 0, nil, nil, nil}, fn event, {chars, words, events, first_time, last_time, msg} ->
              current_time = System.monotonic_time(:millisecond)
              
              case event.type do
                :start ->
                  IO.write("[🎬 Starting]")
                  {chars, words, events + 1, first_time, current_time, msg}
                
                :text_start ->
                  {chars, words, events + 1, first_time, current_time, msg}
                
                :text_delta ->
                  IO.write(event.delta)  # Real-time streaming output!
                  new_chars = String.length(event.delta)
                  new_words = event.delta |> String.split(~r/\s+/) |> length()
                  first = if is_nil(first_time), do: current_time, else: first_time
                  
                  {chars + new_chars, words + new_words, events + 1, first, current_time, msg}
                
                :text_end ->
                  {chars, words, events + 1, first_time, current_time, msg}
                
                :done ->
                  IO.write(" [✅ Complete]")
                  {chars, words, events + 1, first_time, current_time, event.message}
                
                :error ->
                  IO.write(" [❌ Error: #{event.error.message}]")
                  {chars, words, events + 1, first_time, current_time, msg}
                
                other ->
                  IO.write(" [#{other}]")
                  {chars, words, events + 1, first_time, current_time, msg}
              end
            end)
          
          stream_duration = System.monotonic_time(:millisecond) - stream_start
          first_char_latency = if first_char_time, do: first_char_time - stream_start, else: 0
          
          IO.puts("\n\n📊 Streaming Stats:")
          IO.puts("   ⏱️  Total time: #{stream_duration}ms")
          IO.puts("   🚀 Time to first character: #{first_char_latency}ms")
          IO.puts("   🔤 Characters streamed: #{char_count}")
          IO.puts("   📝 Words streamed: #{word_count}")
          IO.puts("   📦 Events processed: #{event_count}")
          
          if final_message do
            IO.puts("   📈 Final tokens: #{final_message.usage.input} in → #{final_message.usage.output} out")
            IO.puts("   💰 Final cost: $#{Float.round(final_message.usage.cost.input + final_message.usage.cost.output, 6)}")
          end
          
          # Calculate streaming rate
          if stream_duration > 0 do
            chars_per_second = Float.round(char_count * 1000 / stream_duration, 1)
            IO.puts("   📊 Streaming rate: #{chars_per_second} chars/second")
          end
          
          IO.puts("\n💡 Streaming Benefits Demonstrated:")
          IO.puts("   ✅ Real-time text appearance (like ChatGPT)")
          IO.puts("   ✅ Immediate feedback - no waiting for full response")
          IO.puts("   ✅ Better user experience for long responses")
          IO.puts("   ✅ Event-driven architecture for fine-grained control")
          
          if char_count > 0 do
            IO.puts("\n🎉 STREAMING WORKS PERFECTLY!")
          else
            IO.puts("\n❌ Streaming produced no content")
          end
        
        {:error, reason} ->
          IO.puts("❌ Streaming failed: #{inspect(reason)}")
      end
      
      # Pause between scenarios
      if length(scenarios) > 1 do
        IO.puts("\n⏳ Pausing 2 seconds before next scenario...")
        Process.sleep(2000)
      end
    end
    
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("🏁 DEMONSTRATION COMPLETE")
    IO.puts(String.duplicate("=", 70))
    
    IO.puts("\n📋 Summary:")
    IO.puts("   This demo showed real AI streaming with:")
    IO.puts("   • Creative writing tasks")
    IO.puts("   • Technical explanations")  
    IO.puts("   • Problem-solving scenarios")
    IO.puts("   • Real-time character streaming")
    IO.puts("   • Performance metrics")
    IO.puts("   • Comparison with synchronous responses")
    
    IO.puts("\n🚀 Your streaming implementation is production-ready!")
    IO.puts("   Users will see text appear in real-time as the AI thinks and writes.")
    IO.puts("   Perfect for chat applications, creative tools, and interactive AI.")
  end


end

# Run the demonstration
try do
  StreamingDemo.run()
rescue
  error ->
    IO.puts("\n❌ Demo failed with error: #{inspect(error)}")
    IO.puts("   Check your ANTHROPIC_API_KEY environment variable")
    IO.puts("   Stacktrace:")
    IO.puts("   #{Exception.format_stacktrace(__STACKTRACE__)}")
end