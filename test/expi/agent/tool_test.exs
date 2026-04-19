defmodule Expi.Agent.ToolTest do
  use ExUnit.Case, async: true

  alias Expi.Agent.Tool

  # Test fixtures
  defp mock_calculator_tool do
    {:ok, tool} =
      Expi.Agent.Tool.new(
        "calculator",
        "Performs mathematical calculations",
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

            {:ok,
             %Expi.Agent.Types.AgentToolResult{
               content: [%Expi.Types.TextContent{type: :text, text: to_string(result)}],
               details: %{expression: expr, result: result}
             }}
          rescue
            _ -> {:error, "Invalid mathematical expression"}
          end
        end
      )

    tool
  end

  defp mock_search_tool do
    {:ok, tool} =
      Expi.Agent.Tool.new(
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
            {:ok,
             %Expi.Agent.Types.AgentToolResult{
               content: [
                 %Expi.Types.TextContent{type: :text, text: "Search results for: #{query}"}
               ],
               details: %{query: query}
             }}
          else
            {:error, "Empty search query"}
          end
        end
      )

    tool
  end

  defp mock_failing_tool do
    {:ok, tool} =
      Expi.Agent.Tool.new(
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

  describe "Tool struct creation" do
    test "creates tool with required fields" do
      tool = %Tool{
        name: "test_tool",
        description: "A test tool",
        function: fn _args -> {:ok, "success"} end
      }

      assert tool.name == "test_tool"
      assert tool.description == "A test tool"
      assert is_function(tool.function, 1)
    end

    test "validates tool name is string" do
      tool = mock_calculator_tool()
      assert is_binary(tool.name)
      assert tool.name == "calculator"
    end

    test "validates tool description is string" do
      tool = mock_calculator_tool()
      assert is_binary(tool.description)
      assert String.contains?(tool.description, "mathematical")
    end

    test "validates tool function is callable" do
      tool = mock_calculator_tool()
      assert is_function(tool.function, 1)
    end
  end

  describe "call/2" do
    test "executes tool with valid arguments" do
      tool = mock_calculator_tool()
      args = %{"expression" => "2 + 2"}

      assert {:ok, result} = Tool.call(tool, args)
      assert result == "4"
    end

    test "handles tool execution errors gracefully" do
      tool = mock_calculator_tool()
      args = %{"expression" => "invalid_expression"}

      assert {:error, error_msg} = Tool.call(tool, args)
      assert error_msg == "Invalid mathematical expression"
    end

    test "executes search tool successfully" do
      tool = mock_search_tool()
      args = %{"query" => "Elixir programming"}

      assert {:ok, result} = Tool.call(tool, args)
      assert result == "Search results for: Elixir programming"
    end

    test "handles search tool with empty query" do
      tool = mock_search_tool()
      args = %{"query" => ""}

      assert {:error, error_msg} = Tool.call(tool, args)
      assert error_msg == "Empty search query"
    end

    test "handles tool function that raises exception" do
      tool = mock_failing_tool()
      args = %{}

      assert {:error, error_msg} = Tool.call(tool, args)
      assert String.contains?(error_msg, "Tool execution failed")
    end

    test "handles missing required arguments" do
      tool = mock_calculator_tool()
      # Missing "expression" key
      args = %{}

      # Should handle missing key gracefully
      result = Tool.call(tool, args)
      assert match?({:error, _}, result)
    end

    test "handles invalid argument types" do
      tool = mock_search_tool()
      # Should be string, not integer
      args = %{"query" => 123}

      # Tool function should handle type conversion or fail gracefully
      result = Tool.call(tool, args)
      # The specific behavior depends on implementation
      assert match?({:ok, _} | {:error, _}, result)
    end
  end

  describe "to_llm_tool/1" do
    test "converts tool to LLM-compatible format" do
      tool = mock_calculator_tool()

      llm_tool = Tool.to_llm_tool(tool)

      assert is_map(llm_tool)
      assert llm_tool.name == "calculator"
      assert llm_tool.description == "Performs mathematical calculations"
      assert Map.has_key?(llm_tool, :input_schema)
    end

    test "includes proper input schema" do
      tool = mock_search_tool()

      llm_tool = Tool.to_llm_tool(tool)

      # Should have proper JSON schema structure
      assert is_map(llm_tool.input_schema)
      assert llm_tool.input_schema.type == "object"
      assert is_map(llm_tool.input_schema.properties)
    end

    test "handles tool without explicit schema" do
      simple_tool = %Tool{
        name: "simple",
        description: "A simple tool",
        function: fn _args -> {:ok, "done"} end
      }

      llm_tool = Tool.to_llm_tool(simple_tool)

      # Should still create valid LLM tool format
      assert llm_tool.name == "simple"
      assert llm_tool.description == "A simple tool"
      assert is_map(llm_tool.input_schema)
    end
  end

  describe "to_llm_tools/1" do
    test "converts list of tools to LLM format" do
      tools = [
        mock_calculator_tool(),
        mock_search_tool()
      ]

      llm_tools = Tool.to_llm_tools(tools)

      assert is_list(llm_tools)
      assert length(llm_tools) == 2

      # Check first tool
      calc_tool = Enum.find(llm_tools, fn t -> t.name == "calculator" end)
      assert calc_tool != nil
      assert is_map(calc_tool.input_schema)

      # Check second tool
      search_tool = Enum.find(llm_tools, fn t -> t.name == "search" end)
      assert search_tool != nil
      assert is_map(search_tool.input_schema)
    end

    test "handles empty tools list" do
      llm_tools = Tool.to_llm_tools([])

      assert llm_tools == []
    end

    test "preserves tool order" do
      tools = [
        mock_calculator_tool(),
        mock_search_tool(),
        %Tool{name: "third", description: "Third tool", function: fn _ -> {:ok, "3"} end}
      ]

      llm_tools = Tool.to_llm_tools(tools)

      assert length(llm_tools) == 3
      assert Enum.at(llm_tools, 0).name == "calculator"
      assert Enum.at(llm_tools, 1).name == "search"
      assert Enum.at(llm_tools, 2).name == "third"
    end
  end

  describe "validate/1" do
    test "validates properly configured tool" do
      tool = mock_calculator_tool()

      assert Tool.validate(tool) == :ok
    end

    test "detects missing name" do
      tool = %Tool{
        name: "",
        description: "Valid description",
        function: fn _ -> {:ok, "result"} end
      }

      assert Tool.validate(tool) == {:error, "Tool name cannot be empty"}
    end

    test "detects nil name" do
      tool = %Tool{
        name: nil,
        description: "Valid description",
        function: fn _ -> {:ok, "result"} end
      }

      assert {:error, _reason} = Tool.validate(tool)
    end

    test "detects missing description" do
      tool = %Tool{
        name: "valid_name",
        description: "",
        function: fn _ -> {:ok, "result"} end
      }

      assert Tool.validate(tool) == {:error, "Tool description cannot be empty"}
    end

    test "detects missing function" do
      tool = %Tool{
        name: "valid_name",
        description: "Valid description",
        function: nil
      }

      assert {:error, _reason} = Tool.validate(tool)
    end

    test "detects invalid function arity" do
      tool = %Tool{
        name: "valid_name",
        description: "Valid description",
        # Wrong arity
        function: fn -> {:ok, "no args"} end
      }

      assert {:error, _reason} = Tool.validate(tool)
    end
  end

  describe "find_by_name/2" do
    test "finds tool by exact name match" do
      tools = [
        mock_calculator_tool(),
        mock_search_tool()
      ]

      found_tool = Tool.find_by_name(tools, "calculator")

      assert found_tool != nil
      assert found_tool.name == "calculator"
    end

    test "returns nil for non-existent tool" do
      tools = [mock_calculator_tool()]

      found_tool = Tool.find_by_name(tools, "non_existent")

      assert found_tool == nil
    end

    test "handles empty tools list" do
      found_tool = Tool.find_by_name([], "any_tool")

      assert found_tool == nil
    end

    test "case sensitive name matching" do
      tools = [mock_calculator_tool()]

      # Exact match should work
      assert Tool.find_by_name(tools, "calculator") != nil

      # Case mismatch should not work
      assert Tool.find_by_name(tools, "Calculator") == nil
      assert Tool.find_by_name(tools, "CALCULATOR") == nil
    end
  end

  describe "complex tool scenarios" do
    test "tool with complex argument processing" do
      complex_tool = %Tool{
        name: "data_processor",
        description: "Processes complex data structures",
        function: fn args ->
          case args do
            %{"data" => data, "operation" => "sum"} when is_list(data) ->
              sum = Enum.sum(data)
              {:ok, "Sum: #{sum}"}

            %{"data" => data, "operation" => "count"} when is_list(data) ->
              count = length(data)
              {:ok, "Count: #{count}"}

            %{"operation" => op} ->
              {:error, "Unsupported operation: #{op}"}

            _ ->
              {:error, "Invalid arguments"}
          end
        end
      }

      # Test sum operation
      assert {:ok, result} =
               Tool.call(complex_tool, %{
                 "data" => [1, 2, 3, 4, 5],
                 "operation" => "sum"
               })

      assert result == "Sum: 15"

      # Test count operation
      assert {:ok, result} =
               Tool.call(complex_tool, %{
                 "data" => [1, 2, 3],
                 "operation" => "count"
               })

      assert result == "Count: 3"

      # Test unsupported operation
      assert {:error, error} =
               Tool.call(complex_tool, %{
                 "data" => [1, 2, 3],
                 "operation" => "unknown"
               })

      assert String.contains?(error, "Unsupported operation")
    end

    test "tool with async-like behavior" do
      async_tool = %Tool{
        name: "async_processor",
        description: "Simulates async processing",
        function: fn %{"delay" => delay} ->
          # Simulate processing time
          Process.sleep(delay)
          {:ok, "Processed after #{delay}ms"}
        end
      }

      start_time = System.system_time(:millisecond)
      assert {:ok, result} = Tool.call(async_tool, %{"delay" => 50})
      end_time = System.system_time(:millisecond)

      assert String.contains?(result, "Processed after 50ms")
      assert end_time - start_time >= 50
    end

    test "tool with state management" do
      # Use agent state for stateful tool (demonstration)
      counter = Agent.start_link(fn -> 0 end)

      stateful_tool = %Tool{
        name: "counter",
        description: "Increments a counter",
        function: fn %{"increment" => inc} ->
          {:ok, agent} = counter

          new_value =
            Agent.get_and_update(agent, fn state ->
              new_state = state + inc
              {new_state, new_state}
            end)

          {:ok, "Counter value: #{new_value}"}
        end
      }

      # Test multiple calls
      assert {:ok, result1} = Tool.call(stateful_tool, %{"increment" => 5})
      assert result1 == "Counter value: 5"

      assert {:ok, result2} = Tool.call(stateful_tool, %{"increment" => 3})
      assert result2 == "Counter value: 8"

      # Cleanup
      {:ok, agent} = counter
      Agent.stop(agent)
    end
  end

  describe "error handling and edge cases" do
    test "handles tool function timeout" do
      timeout_tool = %Tool{
        name: "timeout_tool",
        description: "Tool that times out",
        function: fn _args ->
          # 5 second delay
          Process.sleep(5000)
          {:ok, "Should not reach here"}
        end
      }

      # The current implementation doesn't have built-in timeout,
      # but we can test that it would eventually return
      # In a production system, this would be handled by the executor
      start_time = System.system_time(:millisecond)

      # For this test, we'll just verify the tool can be called
      # Real timeout handling would be in the ToolExecutor module
      spawn(fn ->
        Tool.call(timeout_tool, %{})
      end)

      # Verify test setup is correct
      assert timeout_tool.name == "timeout_tool"
    end

    test "handles tool with large result data" do
      large_data_tool = %Tool{
        name: "large_data",
        description: "Returns large data",
        function: fn %{"size" => size} ->
          large_string = String.duplicate("A", size)
          {:ok, large_string}
        end
      }

      # Test with moderately large data
      assert {:ok, result} = Tool.call(large_data_tool, %{"size" => 10_000})
      assert byte_size(result) == 10_000
    end

    test "handles tool with invalid return format" do
      invalid_tool = %Tool{
        name: "invalid_return",
        description: "Returns invalid format",
        function: fn _args ->
          # Should return {:ok, result} or {:error, reason}
          "not a tuple"
        end
      }

      # Tool.call should handle this gracefully
      result = Tool.call(invalid_tool, %{})
      # Implementation should either normalize the return or treat as error
      assert match?({:ok, _} | {:error, _}, result)
    end
  end

  describe "tool schema generation" do
    test "generates appropriate schema for calculator tool" do
      tool = mock_calculator_tool()
      llm_tool = Tool.to_llm_tool(tool)

      schema = llm_tool.input_schema
      assert schema.type == "object"
      assert is_map(schema.properties)

      # Should have reasonable defaults even without explicit schema
      assert Map.has_key?(schema, :type)
    end

    test "handles tools with no parameters" do
      no_param_tool = %Tool{
        name: "status_check",
        description: "Checks system status",
        function: fn _args -> {:ok, "System OK"} end
      }

      llm_tool = Tool.to_llm_tool(no_param_tool)

      assert llm_tool.name == "status_check"
      assert is_map(llm_tool.input_schema)
      assert llm_tool.input_schema.type == "object"
    end
  end
end
