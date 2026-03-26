defmodule Expi.Agent.ToolResult do
  @moduledoc """
  Tool result handling and aggregation utilities.
  
  This module provides comprehensive utilities for working with tool execution
  results, including aggregation, analysis, formatting, and transformation
  of results for different consumption patterns.
  
  ## Core Functions
  
  - **Analysis**: `analyze_results/1`, `calculate_statistics/1`, `detect_patterns/1`
  - **Aggregation**: `aggregate_by_type/1`, `group_by_status/1`, `merge_results/2`
  - **Transformation**: `format_for_display/1`, `extract_content/1`, `filter_results/2`
  - **Validation**: `validate_results/1`, `check_completeness/2`, `verify_integrity/1`
  
  ## Result Processing
  
  Tool results can be processed in various ways depending on the use case:
  - UI display formatting with rich content extraction
  - Analytics and performance monitoring
  - Error analysis and debugging
  - Content aggregation for follow-up actions
  """

  alias Expi.Types.{ToolResultMessage, TextContent, ImageContent}

  @type result_statistics :: %{
    total_count: non_neg_integer(),
    success_count: non_neg_integer(),
    error_count: non_neg_integer(),
    success_rate: float(),
    average_execution_time: float(),
    total_execution_time: non_neg_integer(),
    content_size_bytes: non_neg_integer()
  }
  
  @type result_pattern :: %{
    pattern_type: :success | :failure | :timeout | :mixed,
    confidence: float(),
    description: String.t(),
    affected_tools: [String.t()],
    recommendation: String.t() | nil
  }

  @type aggregation_options :: [
    group_by: :status | :tool_name | :execution_time | :timestamp,
    include_details: boolean(),
    sort_order: :asc | :desc,
    limit: pos_integer() | nil
  ]

  @doc """
  Analyzes a collection of tool results for patterns and insights.
  
  Provides comprehensive analysis including performance metrics,
  error patterns, content analysis, and execution characteristics.
  
  ## Examples
  
      results = [result1, result2, result3, ...]
      analysis = ToolResult.analyze_results(results)
      
      IO.puts("Success rate: " <> to_string(analysis.statistics.success_rate * 100) <> "%")
      IO.puts("Average execution time: " <> to_string(analysis.statistics.average_execution_time) <> "ms")
      
      Enum.each(analysis.patterns, fn pattern ->
        IO.puts("Pattern detected: " <> pattern.description)
      end)
  """
  @spec analyze_results([ToolResultMessage.t()]) :: %{
    statistics: result_statistics(),
    patterns: [result_pattern()],
    tool_breakdown: map(),
    timeline: [map()]
  }
  def analyze_results(results) when is_list(results) do
    statistics = calculate_statistics(results)
    patterns = detect_patterns(results)
    tool_breakdown = analyze_by_tool(results)
    timeline = create_timeline(results)
    
    %{
      statistics: statistics,
      patterns: patterns,
      tool_breakdown: tool_breakdown,
      timeline: timeline
    }
  end

  @doc """
  Calculates comprehensive statistics for tool execution results.
  
  ## Examples
  
      stats = ToolResult.calculate_statistics(results)
      
      if stats.success_rate < 0.8 do
        investigate_failures(results)
      end
  """
  @spec calculate_statistics([ToolResultMessage.t()]) :: result_statistics()
  def calculate_statistics(results) when is_list(results) do
    total_count = length(results)
    success_count = Enum.count(results, fn r -> not r.is_error end)
    error_count = total_count - success_count
    
    execution_times = extract_execution_times(results)
    total_execution_time = Enum.sum(execution_times)
    average_execution_time = if total_count > 0 do
      total_execution_time / total_count
    else
      0.0
    end
    
    content_size = calculate_content_size(results)
    
    %{
      total_count: total_count,
      success_count: success_count,
      error_count: error_count,
      success_rate: if total_count > 0 do
        success_count / total_count
      else
        0.0
      end,
      average_execution_time: average_execution_time,
      total_execution_time: total_execution_time,
      content_size_bytes: content_size
    }
  end

  @doc """
  Detects patterns in tool execution results.
  
  Identifies common failure patterns, performance issues,
  and execution characteristics that may need attention.
  
  ## Examples
  
      patterns = ToolResult.detect_patterns(results)
      
      timeout_patterns = Enum.filter(patterns, fn p -> 
        p.pattern_type == :timeout 
      end)
  """
  @spec detect_patterns([ToolResultMessage.t()]) :: [result_pattern()]
  def detect_patterns(results) when is_list(results) do
    patterns = []
    
    # Detect high failure rate pattern
    patterns = patterns ++ detect_failure_pattern(results)
    
    # Detect timeout pattern
    patterns = patterns ++ detect_timeout_pattern(results)
    
    # Detect performance pattern
    patterns = patterns ++ detect_performance_pattern(results)
    
    # Detect tool-specific patterns
    patterns = patterns ++ detect_tool_patterns(results)
    
    patterns
  end

  @doc """
  Groups tool results by various criteria with optional sorting and limiting.
  
  ## Examples
  
      # Group by success/failure status
      by_status = ToolResult.aggregate_by_criteria(results, group_by: :status)
      
      # Group by tool name, include details, limit to 10 per group
      by_tool = ToolResult.aggregate_by_criteria(results, 
        group_by: :tool_name,
        include_details: true,
        limit: 10
      )
      
      # Group by execution time ranges
      by_time = ToolResult.aggregate_by_criteria(results, group_by: :execution_time)
  """
  @spec aggregate_by_criteria([ToolResultMessage.t()], aggregation_options()) :: map()
  def aggregate_by_criteria(results, options \\ []) do
    group_by = Keyword.get(options, :group_by, :status)
    include_details = Keyword.get(options, :include_details, false)
    sort_order = Keyword.get(options, :sort_order, :desc)
    limit = Keyword.get(options, :limit)
    
    grouped = case group_by do
      :status -> 
        Enum.group_by(results, fn r -> if r.is_error, do: :error, else: :success end)
      :tool_name -> 
        Enum.group_by(results, & &1.tool_name)
      :execution_time -> 
        group_by_execution_time(results)
      :timestamp -> 
        group_by_time_window(results)
    end
    
    # Apply sorting and limiting
    processed_groups = grouped
    |> Enum.map(fn {key, group_results} ->
      sorted = case sort_order do
        :asc -> Enum.sort_by(group_results, & &1.timestamp)
        :desc -> Enum.sort_by(group_results, & &1.timestamp, :desc)
      end
      
      limited = if limit do
        Enum.take(sorted, limit)
      else
        sorted
      end
      
      group_data = if include_details do
        %{
          count: length(limited),
          results: limited,
          statistics: calculate_statistics(limited)
        }
      else
        %{
          count: length(limited),
          sample: List.first(limited)
        }
      end
      
      {key, group_data}
    end)
    |> Map.new()
    
    processed_groups
  end

  @doc """
  Formats tool results for display in different contexts.
  
  Provides formatted output suitable for different UI components,
  log files, or debugging displays.
  
  ## Examples
  
      # Format for console display
      console_output = ToolResult.format_for_display(results, :console)
      IO.puts(console_output)
      
      # Format for web UI
      ui_data = ToolResult.format_for_display(results, :web_ui)
      
      # Format for logging
      log_entries = ToolResult.format_for_display(results, :log)
  """
  @spec format_for_display([ToolResultMessage.t()], :console | :web_ui | :log | :json) :: 
        String.t() | map() | [map()]
  def format_for_display(results, format \\ :console) do
    case format do
      :console -> format_for_console(results)
      :web_ui -> format_for_web_ui(results)
      :log -> format_for_log(results)
      :json -> format_for_json(results)
    end
  end

  @doc """
  Extracts and consolidates content from multiple tool results.
  
  Combines content from multiple tool executions into a unified
  format suitable for further processing or display.
  
  ## Examples
  
      # Extract all text content
      text_content = ToolResult.extract_content(results, :text)
      
      # Extract images and media
      media_content = ToolResult.extract_content(results, :images)
      
      # Extract all content with metadata
      all_content = ToolResult.extract_content(results, :all)
  """
  @spec extract_content([ToolResultMessage.t()], :text | :images | :all) :: [map()]
  def extract_content(results, content_type \\ :all) do
    results
    |> Enum.flat_map(fn result ->
      extract_result_content(result, content_type)
    end)
    |> Enum.filter(& &1 != nil)
  end

  @doc """
  Filters tool results based on various criteria.
  
  ## Examples
  
      # Get only successful results
      successes = ToolResult.filter_results(results, success: true)
      
      # Get results from specific tools
      search_results = ToolResult.filter_results(results, 
        tool_names: ["web_search", "file_search"]
      )
      
      # Get recent results
      recent = ToolResult.filter_results(results, 
        since: System.system_time(:millisecond) - 3600_000
      )
  """
  @spec filter_results([ToolResultMessage.t()], keyword()) :: [ToolResultMessage.t()]
  def filter_results(results, criteria) do
    Enum.filter(results, fn result ->
      Enum.all?(criteria, fn {key, value} ->
        case key do
          :success -> (not result.is_error) == value
          :error -> result.is_error == value
          :tool_name -> result.tool_name == value
          :tool_names -> result.tool_name in value
          :since -> result.timestamp >= value
          :until -> result.timestamp <= value
          :has_content -> has_meaningful_content?(result)
          :min_execution_time -> get_execution_time(result) >= value
          :max_execution_time -> get_execution_time(result) <= value
          _ -> true
        end
      end)
    end)
  end

  @doc """
  Validates the integrity and completeness of tool results.
  
  Checks for missing data, malformed results, and inconsistencies
  that might indicate problems in tool execution.
  
  ## Examples
  
      case ToolResult.validate_results(results) do
        :ok -> proceed_with_results(results)
        {:error, issues} -> handle_validation_issues(issues)
      end
  """
  @spec validate_results([ToolResultMessage.t()]) :: 
        :ok | {:error, [String.t()]}
  def validate_results(results) when is_list(results) do
    issues = []
    
    # Check for missing required fields
    issues = issues ++ check_required_fields(results)
    
    # Check for duplicate tool call IDs
    issues = issues ++ check_duplicate_ids(results)
    
    # Check for malformed content
    issues = issues ++ check_content_integrity(results)
    
    # Check timestamp consistency
    issues = issues ++ check_timestamp_consistency(results)
    
    case issues do
      [] -> :ok
      _ -> {:error, issues}
    end
  end

  @doc """
  Checks if results are complete for a given set of tool calls.
  
  Verifies that all expected tool calls have corresponding results
  and identifies any missing or incomplete executions.
  
  ## Examples
  
      expected_calls = ["call_1", "call_2", "call_3"]
      
      case ToolResult.check_completeness(results, expected_calls) do
        :complete -> all_tools_executed()
        {:incomplete, missing} -> handle_missing_tools(missing)
      end
  """
  @spec check_completeness([ToolResultMessage.t()], [String.t()]) :: 
        :complete | {:incomplete, [String.t()]}
  def check_completeness(results, expected_tool_call_ids) do
    actual_ids = Enum.map(results, & &1.tool_call_id) |> MapSet.new()
    expected_ids = MapSet.new(expected_tool_call_ids)
    
    missing_ids = MapSet.difference(expected_ids, actual_ids) |> MapSet.to_list()
    
    case missing_ids do
      [] -> :complete
      _ -> {:incomplete, missing_ids}
    end
  end

  @doc """
  Merges multiple tool result collections with conflict resolution.
  
  Combines results from different sources while handling duplicates
  and conflicts intelligently.
  
  ## Examples
  
      # Merge with latest-wins strategy
      merged = ToolResult.merge_results(results1, results2, strategy: :latest)
      
      # Merge with error-priority (keep error results over success)
      merged = ToolResult.merge_results(results1, results2, strategy: :error_priority)
  """
  @spec merge_results([ToolResultMessage.t()], [ToolResultMessage.t()], keyword()) :: 
        [ToolResultMessage.t()]
  def merge_results(results1, results2, options \\ []) do
    strategy = Keyword.get(options, :strategy, :latest)
    
    all_results = results1 ++ results2
    
    # Group by tool_call_id to handle duplicates
    grouped = Enum.group_by(all_results, & &1.tool_call_id)
    
    # Resolve conflicts based on strategy
    resolved = Enum.map(grouped, fn {_id, duplicate_results} ->
      case length(duplicate_results) do
        1 -> List.first(duplicate_results)
        _ -> resolve_conflict(duplicate_results, strategy)
      end
    end)
    
    # Sort by timestamp for consistent ordering
    Enum.sort_by(resolved, & &1.timestamp)
  end

  @doc """
  Creates a summary report of tool execution results.
  
  Generates a comprehensive report suitable for monitoring,
  debugging, or performance analysis.
  
  ## Examples
  
      report = ToolResult.create_summary_report(results,
        include_details: true,
        include_recommendations: true
      )
      
      File.write("tool_execution_report.json", Jason.encode!(report))
  """
  @spec create_summary_report([ToolResultMessage.t()], keyword()) :: map()
  def create_summary_report(results, options \\ []) do
    include_details = Keyword.get(options, :include_details, false)
    include_recommendations = Keyword.get(options, :include_recommendations, false)
    
    analysis = analyze_results(results)
    
    report = %{
      summary: %{
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        total_tools: analysis.statistics.total_count,
        success_rate: analysis.statistics.success_rate,
        total_execution_time: analysis.statistics.total_execution_time
      },
      statistics: analysis.statistics,
      patterns: analysis.patterns,
      tool_breakdown: analysis.tool_breakdown
    }
    
    report = if include_details do
      Map.put(report, :detailed_results, results)
    else
      report
    end
    
    report = if include_recommendations do
      Map.put(report, :recommendations, generate_recommendations(analysis))
    else
      report
    end
    
    report
  end

  # Private helper functions

  @spec extract_execution_times([ToolResultMessage.t()]) :: [number()]
  defp extract_execution_times(results) do
    Enum.map(results, &get_execution_time/1)
  end

  @spec get_execution_time(ToolResultMessage.t()) :: number()
  defp get_execution_time(%ToolResultMessage{details: %{execution_time_ms: time}}) do
    time
  end
  defp get_execution_time(_), do: 0

  @spec calculate_content_size([ToolResultMessage.t()]) :: non_neg_integer()
  defp calculate_content_size(results) do
    results
    |> Enum.map(&estimate_result_size/1)
    |> Enum.sum()
  end

  @spec estimate_result_size(ToolResultMessage.t()) :: non_neg_integer()
  defp estimate_result_size(result) do
    content_size = result.content
    |> Enum.map(&estimate_content_block_size/1)
    |> Enum.sum()
    
    details_size = result.details
    |> inspect()
    |> String.length()
    
    content_size + details_size
  end

  @spec estimate_content_block_size(TextContent.t() | ImageContent.t() | map()) :: non_neg_integer()
  defp estimate_content_block_size(%TextContent{text: text}) do
    String.length(text)
  end
  defp estimate_content_block_size(%ImageContent{data: data}) do
    String.length(data)
  end
  defp estimate_content_block_size(_), do: 100  # Default estimate

  @spec analyze_by_tool([ToolResultMessage.t()]) :: map()
  defp analyze_by_tool(results) do
    results
    |> Enum.group_by(& &1.tool_name)
    |> Enum.map(fn {tool_name, tool_results} ->
      {tool_name, calculate_statistics(tool_results)}
    end)
    |> Map.new()
  end

  @spec create_timeline([ToolResultMessage.t()]) :: [map()]
  defp create_timeline(results) do
    results
    |> Enum.sort_by(& &1.timestamp)
    |> Enum.map(fn result ->
      %{
        timestamp: result.timestamp,
        tool_name: result.tool_name,
        tool_call_id: result.tool_call_id,
        success: not result.is_error,
        execution_time: get_execution_time(result)
      }
    end)
  end

  @spec detect_failure_pattern([ToolResultMessage.t()]) :: [result_pattern()]
  defp detect_failure_pattern(results) do
    stats = calculate_statistics(results)
    
    if stats.success_rate < 0.7 and stats.total_count >= 3 do
      failed_tools = results
      |> Enum.filter(& &1.is_error)
      |> Enum.map(& &1.tool_name)
      |> Enum.uniq()
      
      [%{
        pattern_type: :failure,
        confidence: 1.0 - stats.success_rate,
        description: "High failure rate detected: #{trunc(stats.success_rate * 100)}% success",
        affected_tools: failed_tools,
        recommendation: "Review tool implementations and error handling"
      }]
    else
      []
    end
  end

  @spec detect_timeout_pattern([ToolResultMessage.t()]) :: [result_pattern()]
  defp detect_timeout_pattern(results) do
    timeout_results = results
    |> Enum.filter(fn result ->
      case result.details do
        %{error: :timeout} -> true
        %{crash: _} -> String.contains?(inspect(result.details), "timeout")
        _ -> false
      end
    end)
    
    if length(timeout_results) > length(results) * 0.3 do
      affected_tools = timeout_results
      |> Enum.map(& &1.tool_name)
      |> Enum.uniq()
      
      [%{
        pattern_type: :timeout,
        confidence: length(timeout_results) / length(results),
        description: "Frequent timeouts detected in #{length(timeout_results)} of #{length(results)} executions",
        affected_tools: affected_tools,
        recommendation: "Consider increasing timeout values or optimizing tool performance"
      }]
    else
      []
    end
  end

  @spec detect_performance_pattern([ToolResultMessage.t()]) :: [result_pattern()]
  defp detect_performance_pattern(results) do
    execution_times = extract_execution_times(results)
    
    if execution_times != [] do
      avg_time = Enum.sum(execution_times) / length(execution_times)
      max_time = Enum.max(execution_times)
      
      if avg_time > 10_000 or max_time > 30_000 do
        slow_tools = results
        |> Enum.filter(fn result -> get_execution_time(result) > avg_time * 1.5 end)
        |> Enum.map(& &1.tool_name)
        |> Enum.uniq()
        
        [%{
          pattern_type: :performance,
          confidence: min(1.0, avg_time / 10_000),
          description: "Slow execution times detected: #{trunc(avg_time)}ms average",
          affected_tools: slow_tools,
          recommendation: "Optimize tool implementations or consider caching"
        }]
      else
        []
      end
    else
      []
    end
  end

  @spec detect_tool_patterns([ToolResultMessage.t()]) :: [result_pattern()]
  defp detect_tool_patterns(results) do
    # Analyze patterns specific to individual tools
    results
    |> Enum.group_by(& &1.tool_name)
    |> Enum.flat_map(fn {tool_name, tool_results} ->
      if length(tool_results) >= 3 do
        tool_stats = calculate_statistics(tool_results)
        
        cond do
          tool_stats.success_rate == 0.0 ->
            [%{
              pattern_type: :failure,
              confidence: 1.0,
              description: "Tool '#{tool_name}' always fails",
              affected_tools: [tool_name],
              recommendation: "Check tool configuration and dependencies"
            }]
          tool_stats.success_rate < 0.5 ->
            [%{
              pattern_type: :failure,
              confidence: 0.8,
              description: "Tool '#{tool_name}' has low success rate",
              affected_tools: [tool_name],
              recommendation: "Review tool implementation"
            }]
          true ->
            []
        end
      else
        []
      end
    end)
  end

  @spec group_by_execution_time([ToolResultMessage.t()]) :: map()
  defp group_by_execution_time(results) do
    results
    |> Enum.group_by(fn result ->
      time = get_execution_time(result)
      cond do
        time < 1000 -> :fast
        time < 5000 -> :medium
        time < 15000 -> :slow
        true -> :very_slow
      end
    end)
  end

  @spec group_by_time_window([ToolResultMessage.t()]) :: map()
  defp group_by_time_window(results) do
    # Group by 1-minute time windows
    window_size = 60_000  # 1 minute in milliseconds
    
    results
    |> Enum.group_by(fn result ->
      window = div(result.timestamp, window_size) * window_size
      DateTime.from_unix!(window, :millisecond)
    end)
  end

  # Format functions

  @spec format_for_console([ToolResultMessage.t()]) :: String.t()
  defp format_for_console(results) do
    stats = calculate_statistics(results)
    
    header = "Tool Execution Results (#{stats.total_count} total, #{stats.success_count} successful)"
    separator = String.duplicate("=", String.length(header))
    
    result_lines = results
    |> Enum.with_index(1)
    |> Enum.map(fn {result, index} ->
      status = if result.is_error, do: "❌", else: "✅"
      time = get_execution_time(result)
      "#{index}. #{status} #{result.tool_name} (#{time}ms)"
    end)
    
    summary = "Success Rate: #{trunc(stats.success_rate * 100)}% | " <>
             "Avg Time: #{trunc(stats.average_execution_time)}ms"
    
    [header, separator] ++ result_lines ++ ["", summary]
    |> Enum.join("\n")
  end

  @spec format_for_web_ui([ToolResultMessage.t()]) :: map()
  defp format_for_web_ui(results) do
    %{
      summary: calculate_statistics(results),
      results: Enum.map(results, fn result ->
        %{
          id: result.tool_call_id,
          tool_name: result.tool_name,
          success: not result.is_error,
          execution_time: get_execution_time(result),
          content_preview: extract_content_preview(result),
          timestamp: result.timestamp
        }
      end)
    }
  end

  @spec format_for_log([ToolResultMessage.t()]) :: [map()]
  defp format_for_log(results) do
    Enum.map(results, fn result ->
      %{
        level: if(result.is_error, do: :error, else: :info),
        message: "Tool #{result.tool_name} #{if result.is_error, do: "failed", else: "completed"}",
        metadata: %{
          tool_call_id: result.tool_call_id,
          tool_name: result.tool_name,
          execution_time: get_execution_time(result),
          timestamp: result.timestamp,
          error: result.is_error
        }
      }
    end)
  end

  @spec format_for_json([ToolResultMessage.t()]) :: [map()]
  defp format_for_json(results) do
    Enum.map(results, fn result ->
      %{
        tool_call_id: result.tool_call_id,
        tool_name: result.tool_name,
        success: not result.is_error,
        content: extract_text_from_content(result.content),
        details: result.details,
        timestamp: result.timestamp
      }
    end)
  end

  # Helper functions

  @spec extract_result_content(ToolResultMessage.t(), atom()) :: [map()]
  defp extract_result_content(result, content_type) do
    result.content
    |> Enum.map(fn content_block ->
      case {content_type, content_block} do
        {:text, %TextContent{} = text} -> 
          %{type: :text, content: text.text, source: result.tool_name}
        {:images, %ImageContent{} = image} -> 
          %{type: :image, content: image.data, source: result.tool_name}
        {:all, block} -> 
          %{type: get_content_type(block), content: extract_block_content(block), source: result.tool_name}
        _ -> nil
      end
    end)
    |> Enum.filter(& &1 != nil)
  end

  @spec get_content_type(any()) :: atom()
  defp get_content_type(%TextContent{}), do: :text
  defp get_content_type(%ImageContent{}), do: :image
  defp get_content_type(_), do: :unknown

  @spec extract_block_content(any()) :: String.t()
  defp extract_block_content(%TextContent{text: text}), do: text
  defp extract_block_content(%ImageContent{data: data}), do: data
  defp extract_block_content(_), do: ""

  @spec has_meaningful_content?(ToolResultMessage.t()) :: boolean()
  defp has_meaningful_content?(result) do
    result.content
    |> Enum.any?(fn block ->
      case block do
        %TextContent{text: text} -> String.length(String.trim(text)) > 0
        %ImageContent{data: data} -> String.length(data) > 0
        _ -> false
      end
    end)
  end

  @spec extract_content_preview(ToolResultMessage.t()) :: String.t()
  defp extract_content_preview(result) do
    text_content = extract_text_from_content(result.content)
    if String.length(text_content) > 100 do
      String.slice(text_content, 0, 97) <> "..."
    else
      text_content
    end
  end

  @spec extract_text_from_content([any()]) :: String.t()
  defp extract_text_from_content(content_blocks) do
    content_blocks
    |> Enum.filter(fn block -> match?(%TextContent{}, block) end)
    |> Enum.map(fn %TextContent{text: text} -> text end)
    |> Enum.join(" ")
  end

  # Validation functions

  @spec check_required_fields([ToolResultMessage.t()]) :: [String.t()]
  defp check_required_fields(results) do
    results
    |> Enum.with_index()
    |> Enum.flat_map(fn {result, index} ->
      result_issues = []
      
      result_issues = if is_nil(result.tool_call_id) or result.tool_call_id == "" do
        result_issues ++ ["Result #{index}: missing tool_call_id"]
      else
        result_issues
      end
      
      result_issues = if is_nil(result.tool_name) or result.tool_name == "" do
        result_issues ++ ["Result #{index}: missing tool_name"]
      else
        result_issues
      end
      
      result_issues = if is_nil(result.content) or result.content == [] do
        result_issues ++ ["Result #{index}: missing content"]
      else
        result_issues
      end
      
      result_issues
    end)
  end

  @spec check_duplicate_ids([ToolResultMessage.t()]) :: [String.t()]
  defp check_duplicate_ids(results) do
    id_counts = results
    |> Enum.frequencies_by(& &1.tool_call_id)
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    
    Enum.map(id_counts, fn {id, count} ->
      "Duplicate tool_call_id '#{id}' appears #{count} times"
    end)
  end

  @spec check_content_integrity([ToolResultMessage.t()]) :: [String.t()]
  defp check_content_integrity(results) do
    results
    |> Enum.with_index()
    |> Enum.flat_map(fn {result, index} ->
      if not is_list(result.content) do
        ["Result #{index}: content is not a list"]
      else
        []
      end
    end)
  end

  @spec check_timestamp_consistency([ToolResultMessage.t()]) :: [String.t()]
  defp check_timestamp_consistency(results) do
    invalid_timestamps = results
    |> Enum.with_index()
    |> Enum.filter(fn {result, _index} ->
      not is_integer(result.timestamp) or result.timestamp <= 0
    end)
    
    Enum.map(invalid_timestamps, fn {_result, index} ->
      "Result #{index}: invalid timestamp"
    end)
  end

  @spec resolve_conflict([ToolResultMessage.t()], atom()) :: ToolResultMessage.t()
  defp resolve_conflict(duplicate_results, strategy) do
    case strategy do
      :latest -> 
        Enum.max_by(duplicate_results, & &1.timestamp)
      :error_priority -> 
        error_result = Enum.find(duplicate_results, & &1.is_error)
        error_result || List.first(duplicate_results)
      :success_priority -> 
        success_result = Enum.find(duplicate_results, fn r -> not r.is_error end)
        success_result || List.first(duplicate_results)
      _ -> 
        List.first(duplicate_results)
    end
  end

  @spec generate_recommendations(map()) :: [String.t()]
  defp generate_recommendations(analysis) do
    recommendations = []
    
    # Success rate recommendations
    recommendations = if analysis.statistics.success_rate < 0.8 do
      recommendations ++ ["Consider reviewing failed tool implementations"]
    else
      recommendations
    end
    
    # Performance recommendations
    recommendations = if analysis.statistics.average_execution_time > 10_000 do
      recommendations ++ ["Tool execution times are high - consider optimization"]
    else
      recommendations
    end
    
    # Pattern-based recommendations
    pattern_recommendations = analysis.patterns
    |> Enum.filter(fn pattern -> not is_nil(pattern.recommendation) end)
    |> Enum.map(& &1.recommendation)
    
    recommendations ++ pattern_recommendations
  end
end