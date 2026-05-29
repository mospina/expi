defmodule Expi.AI.BenchmarkTest do
  @moduledoc """
  Performance benchmarks for ExpiAI.

  Run with: mix test --include benchmark

  These tests measure:
  - Request/response latency
  - Throughput under load
  - Memory usage patterns
  - Streaming performance
  - Connection pool efficiency
  """

  use ExUnit.Case, async: false

  alias Expi.AI
  alias Expi.Types.{Context, UserMessage}

  @moduletag :benchmark

  describe "Latency Benchmarks" do
    @tag timeout: 120_000
    test "request latency comparison across providers" do
      providers = get_available_providers()

      if Enum.empty?(providers) do
        IO.puts("⚠️  No providers available for latency benchmark")
        :skip
      else
        results = %{}

        for {provider, model_id} <- providers do
          {:ok, model} = AI.get_model(provider, model_id)

          context = %Context{
            messages: [
              %UserMessage{
                role: :user,
                content: "What is 2+2? Just the number.",
                timestamp: System.system_time(:millisecond)
              }
            ]
          }

          # Warm-up request
          AI.complete_simple(model, context)

          # Measure 5 requests
          latencies =
            for _i <- 1..5 do
              {time_us, {:ok, _response}} =
                :timer.tc(fn ->
                  AI.complete_simple(model, context)
                end)

              # Convert to milliseconds
              time_us / 1000
            end

          avg_latency = Enum.sum(latencies) / length(latencies)
          min_latency = Enum.min(latencies)
          max_latency = Enum.max(latencies)

          results =
            Map.put(results, "#{provider}/#{model_id}", %{
              avg: avg_latency,
              min: min_latency,
              max: max_latency,
              samples: latencies
            })

          IO.puts("📊 #{provider}/#{model_id}:")
          IO.puts("   Average: #{Float.round(avg_latency, 1)}ms")
          IO.puts("   Min: #{Float.round(min_latency, 1)}ms")
          IO.puts("   Max: #{Float.round(max_latency, 1)}ms")
        end

        # Report fastest provider
        fastest =
          results
          |> Enum.min_by(fn {_key, stats} -> stats.avg end)

        {fastest_provider, fastest_stats} = fastest

        IO.puts(
          "\n🏆 Fastest Provider: #{fastest_provider} (#{Float.round(fastest_stats.avg, 1)}ms avg)"
        )

        # Assert reasonable latency (< 30 seconds for simple request)
        Enum.each(results, fn {provider, stats} ->
          assert stats.avg < 30_000, "#{provider} latency too high: #{stats.avg}ms"
        end)
      end
    end
  end

  describe "Throughput Benchmarks" do
    @tag timeout: 300_000
    test "concurrent request throughput" do
      {provider, model_id} = get_fastest_provider()

      if is_nil(provider) do
        IO.puts("⚠️  No providers available for throughput benchmark")
        :skip
      else
        {:ok, model} = AI.get_model(provider, model_id)

        # Test different concurrency levels
        concurrency_levels = [1, 2, 5, 10]
        results = %{}

        for concurrency <- concurrency_levels do
          IO.puts("🧪 Testing concurrency level: #{concurrency}")

          contexts =
            for i <- 1..20 do
              %Context{
                messages: [
                  %UserMessage{
                    role: :user,
                    content: "Count to #{i}",
                    timestamp: System.system_time(:millisecond)
                  }
                ]
              }
            end

          {time_us, responses} =
            :timer.tc(fn ->
              contexts
              |> Task.async_stream(
                fn context -> AI.complete_simple(model, context) end,
                max_concurrency: concurrency,
                timeout: 60_000
              )
              |> Enum.map(fn {:ok, {:ok, response}} -> response end)
            end)

          duration_ms = time_us / 1000
          # requests per second
          throughput = length(responses) / (duration_ms / 1000)

          results =
            Map.put(results, concurrency, %{
              duration_ms: duration_ms,
              throughput: throughput,
              requests: length(responses)
            })

          IO.puts("   Duration: #{Float.round(duration_ms, 1)}ms")
          IO.puts("   Throughput: #{Float.round(throughput, 2)} req/s")
        end

        # Find optimal concurrency
        optimal =
          results
          |> Enum.max_by(fn {_concurrency, stats} -> stats.throughput end)

        {optimal_concurrency, optimal_stats} = optimal

        IO.puts(
          "\n🎯 Optimal Concurrency: #{optimal_concurrency} (#{Float.round(optimal_stats.throughput, 2)} req/s)"
        )

        # Verify throughput is reasonable
        assert optimal_stats.throughput > 0.1,
               "Throughput too low: #{optimal_stats.throughput} req/s"
      end
    end
  end

  describe "Memory Benchmarks" do
    test "memory usage during large requests" do
      {provider, model_id} = get_fastest_provider()

      if is_nil(provider) do
        :skip
      else
        {:ok, model} = AI.get_model(provider, model_id)

        # Measure baseline memory
        :erlang.garbage_collect()
        Process.sleep(100)
        baseline_memory = :erlang.memory(:total)

        # Create a large context
        large_context = %Context{
          system_prompt: String.duplicate("This is a system prompt. ", 100),
          messages:
            for i <- 1..50 do
              %UserMessage{
                role: :user,
                content: "Message #{i}: " <> String.duplicate("content ", 20),
                timestamp: System.system_time(:millisecond)
              }
            end
        }

        # Execute request and measure memory
        {:ok, _response} = AI.complete_simple(model, large_context)

        :erlang.garbage_collect()
        Process.sleep(100)
        peak_memory = :erlang.memory(:total)

        memory_increase = peak_memory - baseline_memory
        memory_increase_mb = memory_increase / (1024 * 1024)

        IO.puts("💾 Memory Usage:")
        IO.puts("   Baseline: #{Float.round(baseline_memory / (1024 * 1024), 1)} MB")
        IO.puts("   Peak: #{Float.round(peak_memory / (1024 * 1024), 1)} MB")
        IO.puts("   Increase: #{Float.round(memory_increase_mb, 1)} MB")

        # Memory increase should be reasonable (< 50MB for this test)
        assert memory_increase_mb < 50, "Memory usage too high: #{memory_increase_mb} MB"
      end
    end
  end

  describe "Streaming Benchmarks" do
    @tag timeout: 180_000
    test "streaming vs synchronous performance" do
      {provider, model_id} = get_fastest_provider()

      if is_nil(provider) do
        :skip
      else
        {:ok, model} = AI.get_model(provider, model_id)

        context = %Context{
          messages: [
            %UserMessage{
              role: :user,
              content: "Write a short paragraph about artificial intelligence",
              timestamp: System.system_time(:millisecond)
            }
          ]
        }

        # Test synchronous request
        {sync_time_us, {:ok, sync_response}} =
          :timer.tc(fn ->
            AI.complete_simple(model, context)
          end)

        sync_time_ms = sync_time_us / 1000
        sync_content_length = get_content_length(sync_response.content)

        # Test streaming request
        {stream_time_us, stream_content_length} =
          :timer.tc(fn ->
            case AI.stream_simple(model, context) do
              {:ok, stream} ->
                content_length =
                  stream
                  |> Stream.filter(&(&1.type == :text_delta))
                  |> Stream.map(&String.length(&1.delta))
                  |> Enum.sum()

                content_length

              {:error, _} ->
                0
            end
          end)

        stream_time_ms = stream_time_us / 1000

        IO.puts("📊 Streaming vs Synchronous:")

        IO.puts(
          "   Sync - Time: #{Float.round(sync_time_ms, 1)}ms, Length: #{sync_content_length} chars"
        )

        IO.puts(
          "   Stream - Time: #{Float.round(stream_time_ms, 1)}ms, Length: #{stream_content_length} chars"
        )

        # Calculate efficiency
        if sync_content_length > 0 and stream_content_length > 0 do
          sync_chars_per_ms = sync_content_length / sync_time_ms
          stream_chars_per_ms = stream_content_length / stream_time_ms

          IO.puts("   Sync Efficiency: #{Float.round(sync_chars_per_ms, 3)} chars/ms")
          IO.puts("   Stream Efficiency: #{Float.round(stream_chars_per_ms, 3)} chars/ms")

          # Streaming might be slightly slower due to overhead, but should be comparable
          efficiency_ratio = stream_chars_per_ms / sync_chars_per_ms
          IO.puts("   Stream/Sync Ratio: #{Float.round(efficiency_ratio, 2)}")

          # Stream efficiency should be at least 50% of synchronous
          assert efficiency_ratio > 0.5,
                 "Streaming too slow compared to sync: #{efficiency_ratio}"
        end
      end
    end

    test "streaming event processing performance" do
      # Create a mock stream of events
      events =
        for i <- 1..1000 do
          %Expi.Types.AssistantMessageEvent{
            type: :text_delta,
            content_index: 0,
            delta: "word#{i} "
          }
        end

      stream = events

      # Measure processing time
      {time_us, result} =
        :timer.tc(fn ->
          stream
          |> Stream.map(fn event ->
            # Simulate some processing
            String.upcase(event.delta)
          end)
          |> Enum.to_list()
        end)

      time_ms = time_us / 1000
      events_per_second = length(events) / (time_ms / 1000)

      IO.puts("⚡ Stream Processing:")
      IO.puts("   Events: #{length(events)}")
      IO.puts("   Time: #{Float.round(time_ms, 1)}ms")
      IO.puts("   Rate: #{Float.round(events_per_second, 0)} events/sec")

      assert length(result) == length(events)

      assert events_per_second > 1000,
             "Event processing too slow: #{events_per_second} events/sec"
    end
  end

  describe "Connection Pool Benchmarks" do
    test "connection pool efficiency" do
      {provider, model_id} = get_fastest_provider()

      if is_nil(provider) do
        :skip
      else
        {:ok, model} = AI.get_model(provider, model_id)

        context = %Context{
          messages: [
            %UserMessage{
              role: :user,
              content: "Hello",
              timestamp: System.system_time(:millisecond)
            }
          ]
        }

        # Test sequential requests (should reuse connections)
        {sequential_time_us, _} =
          :timer.tc(fn ->
            for _i <- 1..5 do
              AI.complete_simple(model, context)
            end
          end)

        # Test concurrent requests (should use connection pool)
        {concurrent_time_us, _} =
          :timer.tc(fn ->
            tasks =
              for _i <- 1..5 do
                Task.async(fn -> AI.complete_simple(model, context) end)
              end

            Task.await_many(tasks, 60_000)
          end)

        sequential_ms = sequential_time_us / 1000
        concurrent_ms = concurrent_time_us / 1000

        speedup = sequential_ms / concurrent_ms

        IO.puts("🔗 Connection Pool Performance:")
        IO.puts("   Sequential: #{Float.round(sequential_ms, 1)}ms")
        IO.puts("   Concurrent: #{Float.round(concurrent_ms, 1)}ms")
        IO.puts("   Speedup: #{Float.round(speedup, 1)}x")

        # Concurrent should be faster (speedup > 1.5x for 5 requests)
        assert speedup > 1.5, "Connection pooling not effective: #{speedup}x speedup"
      end
    end
  end

  describe "Cost Efficiency Benchmarks" do
    test "cost per token across providers" do
      providers = get_available_providers()

      if Enum.empty?(providers) do
        :skip
      else
        results = %{}

        # Standard test prompt
        context = %Context{
          messages: [
            %UserMessage{
              role: :user,
              content: "Explain machine learning in exactly 100 words.",
              timestamp: System.system_time(:millisecond)
            }
          ]
        }

        for {provider, model_id} <- providers do
          {:ok, model} = AI.get_model(provider, model_id)

          {:ok, response} = AI.complete_simple(model, context)

          total_tokens = response.usage.input + response.usage.output
          total_cost = response.usage.cost.input + response.usage.cost.output

          cost_per_token =
            if total_tokens > 0 do
              total_cost / total_tokens
            else
              0.0
            end

          content_length = get_content_length(response.content)

          cost_per_char =
            if content_length > 0 do
              total_cost / content_length
            else
              0.0
            end

          results =
            Map.put(results, "#{provider}/#{model_id}", %{
              total_cost: total_cost,
              tokens: total_tokens,
              chars: content_length,
              cost_per_token: cost_per_token,
              cost_per_char: cost_per_char
            })

          IO.puts("💰 #{provider}/#{model_id}:")
          IO.puts("   Total Cost: $#{Float.round(total_cost, 6)}")
          IO.puts("   Tokens: #{total_tokens}")
          IO.puts("   Cost/Token: $#{Float.round(cost_per_token, 8)}")
          IO.puts("   Cost/Char: $#{Float.round(cost_per_char, 8)}")
        end

        # Find most cost-effective provider
        cheapest =
          results
          |> Enum.filter(fn {_key, stats} -> stats.total_cost > 0 end)
          |> case do
            [] -> nil
            non_empty -> Enum.min_by(non_empty, fn {_key, stats} -> stats.cost_per_token end)
          end

        if cheapest do
          {cheapest_provider, cheapest_stats} = cheapest

          IO.puts(
            "\n💸 Most Cost-Effective: #{cheapest_provider} ($#{Float.round(cheapest_stats.cost_per_token, 8)}/token)"
          )
        else
          IO.puts("\n🏠 All tested providers are free (local models)")
        end
      end
    end
  end

  # Helper functions

  defp get_available_providers do
    providers = []

    # Check Anthropic
    providers =
      if System.get_env("ANTHROPIC_API_KEY") do
        [{"anthropic", "claude-sonnet-3-6"} | providers]
      else
        providers
      end

    # Check Google
    providers =
      if System.get_env("GOOGLE_API_KEY") do
        [{"google", "gemini-pro"} | providers]
      else
        providers
      end

    # Check Ollama
    providers =
      if test_ollama_connection() == :ok do
        case AI.get_model("ollama", "llama3.1:8b") do
          {:ok, _} -> [{"ollama", "llama3.1:8b"} | providers]
          {:error, _} -> providers
        end
      else
        providers
      end

    providers
  end

  defp get_fastest_provider do
    providers = get_available_providers()

    case providers do
      [] -> {nil, nil}
      [provider | _] -> provider
    end
  end

  defp get_content_length(content) when is_list(content) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map(&String.length(&1.text))
    |> Enum.sum()
  end

  defp get_content_length(content) when is_binary(content), do: String.length(content)
  defp get_content_length(_), do: 0

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
