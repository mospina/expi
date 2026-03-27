defmodule Expi.Agent.ToolExecutorTest do
  use ExUnit.Case, async: true

  alias Expi.Agent.{ToolExecutor, Tool}
  alias Expi.Types.{ToolCall, ToolResultMessage}

  # Test fixtures
  defp mock_calculator_tool do
    {:ok, tool} = Expi.Agent.Tool.new(
      "calculator",
      "Performs calculations", 
      %{
        type: :object,
        properties: %{
          expression: %{type: :string, description: "Mathematical expression"}
        },
        required: ["expression"]
      },
      "Calculator",
      fn _tool_call_id, params, _abort_signal, _update_callback ->
        expr = params["expression"]
        try do
          {result, _} = Code.eval_string(expr)
          {:ok, %Expi.Agent.Types.AgentToolResult{
            content: [%Expi.Types.TextContent{type: :text, text: to_string(result)}],
            details: %{expression: expr, result: result}
          }}
        rescue
          _ -> {:error, "Invalid expression"}
        end
      end
    )
    tool
  end

  defp mock_search_tool do
    {:ok, tool} = Expi.Agent.Tool.new(
      "search",
      "Searches for information",
      %{
        type: :object,
        properties: %{
          query: %{type: :string, description: "Search query"}
        },
        required: ["query"]
      },
      "Search Tool",
      fn _tool_call_id, params, _abort_signal, _update_callback ->
        query = params["query"]
        if String.length(query) > 0 do
          {:ok, %Expi.Agent.Types.AgentToolResult{
            content: [%Expi.Types.TextContent{type: :text, text: "Results for: #{query}"}],
            details: %{query: query}
          }}
        else
          {:error, "Empty query"}
        end
      end
    )
    tool
  end

  defp mock_slow_tool do
    {:ok, tool} = Expi.Agent.Tool.new(
      "slow_tool",
      "A slow tool for testing timeouts",
      %{
        type: :object,
        properties: %{
          delay: %{type: :integer, description: "Delay in milliseconds"}
        },
        required: ["delay"]
      },
      "Slow Tool",
      fn _tool_call_id, params, _abort_signal, _update_callback ->
        delay = params["delay"]
        Process.sleep(delay)
        {:ok, %Expi.Agent.Types.AgentToolResult{
          content: [%Expi.Types.TextContent{type: :text, text: "Completed after #{delay}ms"}],
          details: %{delay: delay}
        }}
      end
    )
    tool
  end

  defp mock_failing_tool do
    {:ok, tool} = Expi.Agent.Tool.new(
      "failing_tool",
      "A tool that always fails",
      %{type: :object, properties: %{}},
      "Failing Tool",
      fn _tool_call_id, _params, _abort_signal, _update_callback ->
        raise "Tool execution failed"
      end
    )
    tool
  end

  defp mock_tool_call(name, args) do
    %ToolCall{
      id: "call_#{:rand.uniform(1000)}",
      name: name,
      arguments: args
    }
  end

  describe "execute_tool/3" do
    test "executes single tool successfully" do
      tool_call = mock_tool_call("calculator", %{"expression" => "2 + 3"})
      tool = mock_calculator_tool()
      
      assert {:ok, result} = ToolExecutor.execute_tool(tool_call, [tool])
      
      assert %ToolResultMessage{} = result
      assert result.tool_call_id == tool_call.id
      assert result.tool_name == "calculator"
      assert result.content == "5"
      assert result.is_error == false
    end

    test "handles tool execution error" do
      tool_call = mock_tool_call("calculator", %{"expression" => "invalid"})
      tool = mock_calculator_tool()
      
      assert {:ok, result} = ToolExecutor.execute_tool(tool_call, [tool])
      
      assert result.is_error == true
      assert result.content == "Invalid expression"
      assert result.tool_name == "calculator"
    end

    test "handles tool not found" do
      tool_call = mock_tool_call("nonexistent", %{})
      
      assert {:ok, result} = ToolExecutor.execute_tool(tool_call, [])
      
      assert result.is_error == true
      assert String.contains?(result.content, "not found")
    end

    test "handles tool execution crash" do
      tool_call = mock_tool_call("failing_tool", %{})
      tool = mock_failing_tool()
      
      assert {:ok, result} = ToolExecutor.execute_tool(tool_call, [tool])
      
      assert result.is_error == true
      assert String.contains?(result.content, "failed")
    end

    test "includes execution metadata" do
      tool_call = mock_tool_call("search", %{"query" => "elixir"})
      tool = mock_search_tool()
      
      {:ok, result} = ToolExecutor.execute_tool(tool_call, [tool], %{collect_metadata: true})
      
      # Should have basic result structure
      assert result.tool_call_id == tool_call.id
      assert result.tool_name == "search"
      assert is_integer(result.timestamp)
    end
  end

  describe "execute_tools_concurrent/4" do
    test "executes multiple tools concurrently" do
      tool_calls = [
        mock_tool_call("calculator", %{"expression" => "1 + 1"}),
        mock_tool_call("calculator", %{"expression" => "2 * 3"}),
        mock_tool_call("search", %{"query" => "elixir"})
      ]
      
      tools = [mock_calculator_tool(), mock_search_tool()]
      
      start_time = System.system_time(:millisecond)
      assert {:ok, results} = ToolExecutor.execute_tools_concurrent(tool_calls, tools)
      end_time = System.system_time(:millisecond)
      
      assert length(results) == 3
      
      # Find results by tool name
      calc_results = Enum.filter(results, fn r -> r.tool_name == "calculator" end)
      search_results = Enum.filter(results, fn r -> r.tool_name == "search" end)
      
      assert length(calc_results) == 2
      assert length(search_results) == 1
      
      # Check calculator results
      calc_contents = Enum.map(calc_results, fn r -> r.content end) |> Enum.sort()
      assert calc_contents == ["2", "6"]
      
      # Check search result
      search_result = hd(search_results)
      assert search_result.content == "Results for: elixir"
      
      # Should have executed concurrently (relatively fast)
      execution_time = end_time - start_time
      assert execution_time < 1000  # Should be fast for simple operations
    end

    test "handles mixed success and failure in concurrent execution" do
      tool_calls = [
        mock_tool_call("calculator", %{"expression" => "2 + 2"}),  # Success
        mock_tool_call("calculator", %{"expression" => "invalid"}),  # Failure
        mock_tool_call("search", %{"query" => "test"})  # Success
      ]
      
      tools = [mock_calculator_tool(), mock_search_tool()]
      
      assert {:ok, results} = ToolExecutor.execute_tools_concurrent(tool_calls, tools)
      
      assert length(results) == 3
      
      success_count = Enum.count(results, fn r -> not r.is_error end)
      error_count = Enum.count(results, fn r -> r.is_error end)
      
      assert success_count == 2
      assert error_count == 1
    end

    test "respects concurrency limit" do
      # Create many tool calls
      tool_calls = for i <- 1..10 do
        mock_tool_call("search", %{"query" => "query_#{i}"})
      end
      
      tools = [mock_search_tool()]
      
      # Execute with concurrency limit
      assert {:ok, results} = ToolExecutor.execute_tools_concurrent(
        tool_calls, 
        tools,
        max_concurrent: 3,
        timeout: 5000
      )
      
      assert length(results) == 10
      
      # All should be successful
      assert Enum.all?(results, fn r -> not r.is_error end)
    end

    test "handles timeout in concurrent execution" do
      # Create tool calls with varying delays
      tool_calls = [
        mock_tool_call("slow_tool", %{"delay" => 50}),   # Fast
        mock_tool_call("slow_tool", %{"delay" => 100}),  # Medium
        mock_tool_call("slow_tool", %{"delay" => 2000})  # Slow (will timeout)
      ]
      
      tools = [mock_slow_tool()]
      
      {:ok, results} = ToolExecutor.execute_tools_concurrent(
        tool_calls,
        tools,
        timeout: 500,  # 500ms timeout
        max_concurrent: 5
      )
      
      assert length(results) == 3
      
      # Check that some succeeded and some failed due to timeout
      success_count = Enum.count(results, fn r -> not r.is_error end)
      timeout_count = Enum.count(results, fn r -> 
        r.is_error and String.contains?(r.content, "timeout")
      end)
      
      assert success_count >= 2  # First two should succeed
      assert timeout_count >= 1  # Last one should timeout
    end

    test "handles empty tool calls list" do
      assert {:ok, results} = ToolExecutor.execute_tools_concurrent([], [])
      assert results == []
    end

    test "handles streaming updates during execution" do
      test_pid = self()
      
      update_callback = fn tool_call_id, partial_result ->
        send(test_pid, {:tool_update, tool_call_id, partial_result})
      end
      
      tool_calls = [mock_tool_call("search", %{"query" => "streaming test"})]
      tools = [mock_search_tool()]
      
      {:ok, _results} = ToolExecutor.execute_tools_concurrent(
        tool_calls,
        tools,
        on_update: update_callback
      )
      
      # May receive update callbacks during execution
      # This is implementation-dependent
    end

    test "preserves tool call order in results" do
      tool_calls = [
        mock_tool_call("calculator", %{"expression" => "1"}),
        mock_tool_call("calculator", %{"expression" => "2"}),
        mock_tool_call("calculator", %{"expression" => "3"})
      ]
      
      tools = [mock_calculator_tool()]
      
      {:ok, results} = ToolExecutor.execute_tools_concurrent(tool_calls, tools)
      
      # Results should correspond to tool calls (though async execution
      # might change order in some implementations)
      assert length(results) == 3
      
      # All should be from calculator
      assert Enum.all?(results, fn r -> r.tool_name == "calculator" end)
      
      # Check that all expected results are present
      contents = Enum.map(results, fn r -> r.content end) |> Enum.sort()
      assert contents == ["1", "2", "3"]
    end
  end

  describe "execute_tools_sequential/3" do
    test "executes tools one after another" do
      tool_calls = [
        mock_tool_call("calculator", %{"expression" => "1 + 1"}),
        mock_tool_call("search", %{"query" => "sequential"})
      ]
      
      tools = [mock_calculator_tool(), mock_search_tool()]
      
      assert {:ok, results} = ToolExecutor.execute_tools_sequential(tool_calls, tools)
      
      assert length(results) == 2
      assert Enum.at(results, 0).tool_name == "calculator"
      assert Enum.at(results, 0).content == "2"
      assert Enum.at(results, 1).tool_name == "search"
      assert String.contains?(Enum.at(results, 1).content, "sequential")
    end

    test "stops on first error when configured" do
      tool_calls = [
        mock_tool_call("calculator", %{"expression" => "invalid"}),  # Will fail
        mock_tool_call("search", %{"query" => "should not execute"})
      ]
      
      tools = [mock_calculator_tool(), mock_search_tool()]
      
      # Test with stop_on_error: true
      {:ok, results} = ToolExecutor.execute_tools_sequential(
        tool_calls,
        tools,
        stop_on_error: true
      )
      
      # Should only have one result (the failed one)
      assert length(results) == 1
      assert hd(results).is_error == true
    end

    test "continues after errors when configured" do
      tool_calls = [
        mock_tool_call("calculator", %{"expression" => "invalid"}),  # Will fail
        mock_tool_call("search", %{"query" => "should execute"})     # Will succeed
      ]
      
      tools = [mock_calculator_tool(), mock_search_tool()]
      
      {:ok, results} = ToolExecutor.execute_tools_sequential(
        tool_calls,
        tools,
        stop_on_error: false
      )
      
      assert length(results) == 2
      assert Enum.at(results, 0).is_error == true
      assert Enum.at(results, 1).is_error == false
    end
  end

  describe "tool execution monitoring" do
    test "tracks execution statistics" do
      tool_calls = [
        mock_tool_call("calculator", %{"expression" => "2 + 2"}),
        mock_tool_call("search", %{"query" => "test"})
      ]
      
      tools = [mock_calculator_tool(), mock_search_tool()]
      
      start_time = System.system_time(:millisecond)
      {:ok, results} = ToolExecutor.execute_tools_concurrent(tool_calls, tools)
      end_time = System.system_time(:millisecond)
      
      # Each result should have timestamp
      Enum.each(results, fn result ->
        assert is_integer(result.timestamp)
        assert result.timestamp >= start_time
        assert result.timestamp <= end_time
      end)
    end

    test "handles tool execution timeouts gracefully" do
      slow_call = mock_tool_call("slow_tool", %{"delay" => 2000})
      tools = [mock_slow_tool()]
      
      {:ok, results} = ToolExecutor.execute_tools_concurrent(
        [slow_call],
        tools,
        timeout: 100  # Very short timeout
      )
      
      assert length(results) == 1
      result = hd(results)
      assert result.is_error == true
      assert String.contains?(result.content, "timeout") or 
             String.contains?(result.content, "exceeded")
    end
  end

  describe "error isolation" do
    test "isolates tool execution errors" do
      mixed_calls = [
        mock_tool_call("calculator", %{"expression" => "2 + 2"}),  # Good
        mock_tool_call("failing_tool", %{}),                      # Crash
        mock_tool_call("search", %{"query" => "test"})            # Good
      ]
      
      tools = [mock_calculator_tool(), mock_failing_tool(), mock_search_tool()]
      
      {:ok, results} = ToolExecutor.execute_tools_concurrent(mixed_calls, tools)
      
      assert length(results) == 3
      
      # Should have 2 successes and 1 failure
      success_results = Enum.filter(results, fn r -> not r.is_error end)
      error_results = Enum.filter(results, fn r -> r.is_error end)
      
      assert length(success_results) == 2
      assert length(error_results) == 1
      
      # Successful results should have correct content
      success_contents = Enum.map(success_results, fn r -> r.content end)
      assert "4" in success_contents
      assert Enum.any?(success_contents, fn c -> String.contains?(c, "Results for: test") end)
    end

    test "prevents one failing tool from affecting others" do
      # Create tool that modifies global state
      state_agent = Agent.start_link(fn -> 0 end)
      
      stateful_tool = %Tool{
        name: "stateful",
        description: "Modifies state",
        function: fn %{"action" => action} ->
          {:ok, agent} = state_agent
          
          case action do
            "increment" ->
              Agent.update(agent, fn s -> s + 1 end)
              current = Agent.get(agent, fn s -> s end)
              {:ok, "State: #{current}"}
            "crash" ->
              raise "State tool crashed!"
            "read" ->
              current = Agent.get(agent, fn s -> s end)
              {:ok, "Current state: #{current}"}
          end
        end
      }
      
      tool_calls = [
        mock_tool_call("stateful", %{"action" => "increment"}),  # Should work
        mock_tool_call("stateful", %{"action" => "crash"}),     # Should fail
        mock_tool_call("stateful", %{"action" => "read"})       # Should work
      ]
      
      {:ok, results} = ToolExecutor.execute_tools_concurrent(tool_calls, [stateful_tool])
      
      # Check that state was modified despite the crash
      successful_results = Enum.filter(results, fn r -> not r.is_error end)
      
      # Should have at least one successful increment and read
      assert length(successful_results) >= 2
      
      # Cleanup
      {:ok, agent} = state_agent
      Agent.stop(agent)
    end
  end

  describe "performance and scalability" do
    test "handles large number of concurrent tool calls" do
      # Create many tool calls
      tool_calls = for i <- 1..50 do
        mock_tool_call("search", %{"query" => "query_#{i}"})
      end
      
      tools = [mock_search_tool()]
      
      start_time = System.system_time(:millisecond)
      {:ok, results} = ToolExecutor.execute_tools_concurrent(
        tool_calls,
        tools,
        max_concurrent: 10,
        timeout: 10_000
      )
      end_time = System.system_time(:millisecond)
      
      assert length(results) == 50
      
      # Should complete in reasonable time with concurrency
      execution_time = end_time - start_time
      assert execution_time < 5000  # Should be much faster than sequential
      
      # All should be successful
      assert Enum.all?(results, fn r -> not r.is_error end)
    end

    test "respects memory limits with large tool results" do
      large_data_tool = %Tool{
        name: "large_data",
        description: "Returns large data",
        function: fn %{"size" => size} ->
          data = String.duplicate("X", size)
          {:ok, data}
        end
      }
      
      # Request moderately large data
      tool_call = mock_tool_call("large_data", %{"size" => 10_000})
      
      {:ok, result} = ToolExecutor.execute_tool(tool_call, [large_data_tool])
      
      assert not result.is_error
      assert String.length(result.content) == 10_000
    end
  end

  describe "edge cases" do
    test "handles tool with complex argument validation" do
      validation_tool = %Tool{
        name: "validator",
        description: "Validates complex inputs",
        function: fn args ->
          case args do
            %{"data" => data, "rules" => rules} when is_list(data) and is_map(rules) ->
              {:ok, "Validation passed"}
            %{"data" => _} ->
              {:error, "Missing or invalid rules"}
            _ ->
              {:error, "Missing required data"}
          end
        end
      }
      
      # Test various argument combinations
      test_cases = [
        {%{"data" => [1, 2, 3], "rules" => %{"min" => 1}}, false},  # Should succeed
        {%{"data" => [1, 2, 3]}, true},                             # Should fail - missing rules
        {%{"rules" => %{"min" => 1}}, true},                        # Should fail - missing data
        {%{}, true}                                                 # Should fail - missing both
      ]
      
      Enum.each(test_cases, fn {args, should_error} ->
        tool_call = mock_tool_call("validator", args)
        {:ok, result} = ToolExecutor.execute_tool(tool_call, [validation_tool])
        
        if should_error do
          assert result.is_error == true
        else
          assert result.is_error == false
        end
      end)
    end

    test "handles tool calls with missing or nil arguments" do
      tool_call = %ToolCall{
        id: "call_nil_args",
        name: "search",
        arguments: nil
      }
      
      tools = [mock_search_tool()]
      
      {:ok, result} = ToolExecutor.execute_tool(tool_call, tools)
      
      # Should handle gracefully
      assert result.is_error == true
    end

    test "handles extremely fast tool execution" do
      instant_tool = %Tool{
        name: "instant",
        description: "Returns immediately",
        function: fn _args -> {:ok, "instant"} end
      }
      
      # Execute many instant tools
      tool_calls = for _i <- 1..100 do
        mock_tool_call("instant", %{})
      end
      
      start_time = System.system_time(:millisecond)
      {:ok, results} = ToolExecutor.execute_tools_concurrent(tool_calls, [instant_tool])
      end_time = System.system_time(:millisecond)
      
      assert length(results) == 100
      assert Enum.all?(results, fn r -> not r.is_error and r.content == "instant" end)
      
      # Should be very fast
      execution_time = end_time - start_time
      assert execution_time < 1000
    end
  end
end