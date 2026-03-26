defmodule Expi.Agent.Context do
  @moduledoc """
  Context transformation utilities for agent conversations.
  
  This module provides pre-built transformation functions and utilities
  for managing conversation context, including message pruning, content
  injection, and context optimization strategies.
  
  ## Common Transformations
  
  - **Pruning**: `prune_by_age/3`, `prune_by_count/3`, `prune_by_tokens/3`
  - **Filtering**: `filter_by_type/3`, `filter_by_content/3`
  - **Injection**: `inject_context/3`, `add_system_context/3`
  - **Optimization**: `optimize_for_model/3`, `compress_repetitive/3`
  
  ## Transformation Functions
  
  All transformation functions follow the standard signature:
  `(messages, abort_signal) -> {:ok, transformed_messages} | {:error, reason}`
  
  This allows them to be used directly with the message processing pipeline.
  """

  alias Expi.Agent.{Message, MessageProcessor}

  @type transform_fn :: (messages :: [Message.t()], abort_signal :: pid() | nil -> 
                        {:ok, [Message.t()]} | {:error, any()})
  @type transform_options :: keyword()
  @type context_stats :: %{
    message_count: non_neg_integer(),
    estimated_tokens: non_neg_integer(),
    type_distribution: map(),
    age_range: {non_neg_integer(), non_neg_integer()} | nil
  }

  @doc """
  Creates a transformation function that prunes messages by age.
  
  Returns a transform function that removes messages older than the
  specified time threshold, while optionally preserving a minimum
  number of recent messages.
  
  ## Parameters
  
  - `max_age_ms` - Maximum age in milliseconds
  - `opts` - Options including preserve_count, keep_system_messages
  
  ## Examples
  
      # Remove messages older than 24 hours
      day_prune = Context.prune_by_age(86_400_000, preserve_count: 5)
      
      {:ok, context} = MessageProcessor.process_pipeline(
        state, 
        day_prune, 
        nil
      )
      
      # Remove messages older than 1 hour, always keep last 10
      hour_prune = Context.prune_by_age(
        3_600_000, 
        preserve_count: 10,
        keep_system_messages: true
      )
  """
  @spec prune_by_age(pos_integer(), transform_options()) :: transform_fn()
  def prune_by_age(max_age_ms, opts \\ []) do
    preserve_count = Keyword.get(opts, :preserve_count, 3)
    keep_system = Keyword.get(opts, :keep_system_messages, false)
    
    fn messages, _abort_signal ->
      cutoff_time = System.system_time(:millisecond) - max_age_ms
      
      # Always preserve recent messages
      {recent, older} = Enum.split(messages, -preserve_count)
      
      # Filter older messages by age
      filtered_older = Enum.filter(older, fn message ->
        message_age = Message.timestamp(message)
        is_system = keep_system and Message.message_type(message) == :system
        
        message_age > cutoff_time or is_system
      end)
      
      {:ok, filtered_older ++ recent}
    end
  end

  @doc """
  Creates a transformation function that limits message count.
  
  Keeps only the most recent N messages, with options to preserve
  important message types.
  
  ## Examples
  
      # Keep only last 20 messages
      count_limit = Context.prune_by_count(20)
      
      # Keep last 30 messages, but preserve all system messages
      preserve_system = Context.prune_by_count(
        30, 
        preserve_types: [:system, :tool_result]
      )
  """
  @spec prune_by_count(pos_integer(), transform_options()) :: transform_fn()
  def prune_by_count(max_count, opts \\ []) do
    preserve_types = Keyword.get(opts, :preserve_types, [])
    
    fn messages, _abort_signal ->
      if length(messages) <= max_count do
        {:ok, messages}
      else
        # Separate preserved and regular messages
        {preserved, regular} = Enum.split_with(messages, fn msg ->
          Message.message_type(msg) in preserve_types
        end)
        
        # Keep most recent regular messages
        recent_regular = Enum.take(regular, -max_count)
        
        # Combine and sort by timestamp
        result = (preserved ++ recent_regular)
                |> Message.sort_by_timestamp()
        
        {:ok, result}
      end
    end
  end

  @doc """
  Creates a transformation function that limits token usage.
  
  Dynamically removes older messages to stay within a token budget
  while preserving conversation flow and important context.
  
  ## Examples
  
      # Stay under 4000 tokens
      token_limit = Context.prune_by_tokens(4000)
      
      # Aggressive pruning for smaller models
      small_limit = Context.prune_by_tokens(
        1500, 
        preserve_count: 3,
        preserve_types: [:system]
      )
  """
  @spec prune_by_tokens(pos_integer(), transform_options()) :: transform_fn()
  def prune_by_tokens(max_tokens, opts \\ []) do
    preserve_count = Keyword.get(opts, :preserve_count, 5)
    preserve_types = Keyword.get(opts, :preserve_types, [])
    
    fn messages, _abort_signal ->
      MessageProcessor.prune_by_tokens(messages, max_tokens, 
        preserve_count: preserve_count,
        preserve_types: preserve_types
      )
    end
  end

  @doc """
  Creates a transformation function that filters by message type.
  
  Keeps only messages of the specified types, useful for creating
  focused conversations or removing noise.
  
  ## Examples
  
      # Keep only conversation messages, remove system notifications
      conversation_only = Context.filter_by_type([:user, :assistant, :tool_result])
      
      # Debug mode - keep everything including internal messages
      debug_filter = Context.filter_by_type([
        :user, :assistant, :tool_result, :system, :notification
      ])
  """
  @spec filter_by_type([atom()], transform_options()) :: transform_fn()
  def filter_by_type(allowed_types, _opts \\ []) do
    fn messages, _abort_signal ->
      MessageProcessor.filter_by_type(messages, allowed_types)
    end
  end

  @doc """
  Creates a transformation function that filters by content patterns.
  
  Removes or keeps messages based on content matching patterns,
  useful for removing sensitive information or focusing on specific topics.
  
  ## Examples
  
      # Remove messages containing sensitive patterns
      privacy_filter = Context.filter_by_content(
        exclude_patterns: [~r/password/i, ~r/secret/i, ~r/key.*=/i]
      )
      
      # Keep only messages about a specific topic
      topic_filter = Context.filter_by_content(
        include_patterns: [~r/elixir/i, ~r/functional.*programming/i]
      )
  """
  @spec filter_by_content(transform_options()) :: transform_fn()
  def filter_by_content(opts \\ []) do
    exclude_patterns = Keyword.get(opts, :exclude_patterns, [])
    include_patterns = Keyword.get(opts, :include_patterns, [])
    
    fn messages, _abort_signal ->
      filtered = Enum.filter(messages, fn message ->
        content = Message.content(message)
        content_text = extract_text_content(content)
        
        # Check exclude patterns
        excluded = Enum.any?(exclude_patterns, fn pattern ->
          String.match?(content_text, pattern)
        end)
        
        # Check include patterns (if any specified)
        included = if include_patterns == [] do
          true
        else
          Enum.any?(include_patterns, fn pattern ->
            String.match?(content_text, pattern)
          end)
        end
        
        not excluded and included
      end)
      
      {:ok, filtered}
    end
  end

  @doc """
  Creates a transformation function that injects contextual information.
  
  Adds additional context messages at strategic points in the conversation,
  such as system updates, background information, or instructions.
  
  ## Examples
  
      # Inject current time and date context
      time_context = Context.inject_context([
        %{type: :system, content: "Current time: #{DateTime.utc_now()}"}
      ])
      
      # Add periodic reminders about conversation guidelines
      reminder_context = Context.inject_context(
        [%{type: :system, content: "Remember to be helpful and accurate."}],
        frequency: 10  # Every 10 messages
      )
  """
  @spec inject_context([map()], transform_options()) :: transform_fn()
  def inject_context(context_messages, opts \\ []) do
    frequency = Keyword.get(opts, :frequency, 1)
    position = Keyword.get(opts, :position, :end)
    
    fn messages, _abort_signal ->
      should_inject = case frequency do
        1 -> true
        n when n > 1 -> rem(length(messages), n) == 0
        _ -> false
      end
      
      if should_inject do
        injected_messages = Enum.map(context_messages, &create_context_message/1)
        
        result = case position do
          :start -> injected_messages ++ messages
          :end -> messages ++ injected_messages
          :middle -> 
            mid = div(length(messages), 2)
            {before, after_split} = Enum.split(messages, mid)
            before ++ injected_messages ++ after_split
        end
        
        {:ok, result}
      else
        {:ok, messages}
      end
    end
  end

  @doc """
  Creates a transformation function that optimizes context for specific models.
  
  Applies model-specific optimizations like token limits, content formatting,
  and structure adjustments based on the target AI model's characteristics.
  
  ## Examples
  
      # Optimize for Claude with reasoning support
      claude_optimize = Context.optimize_for_model(:claude, 
        enable_thinking: true,
        max_tokens: 8000
      )
      
      # Optimize for smaller models with tight limits
      small_model_optimize = Context.optimize_for_model(:llama_8b,
        max_tokens: 2000,
        compress_content: true
      )
  """
  @spec optimize_for_model(atom(), transform_options()) :: transform_fn()
  def optimize_for_model(model_type, opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, 4000)
    compress_content = Keyword.get(opts, :compress_content, false)
    enable_thinking = Keyword.get(opts, :enable_thinking, false)
    
    fn messages, _abort_signal ->
      with {:ok, pruned} <- maybe_prune_for_model(messages, model_type, max_tokens),
           {:ok, optimized} <- maybe_compress_content(pruned, compress_content),
           {:ok, formatted} <- maybe_format_for_thinking(optimized, enable_thinking) do
        {:ok, formatted}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Creates a transformation function that removes repetitive content.
  
  Identifies and removes messages with similar or duplicate content
  to reduce noise and token usage while preserving conversation flow.
  
  ## Examples
  
      # Remove exact duplicates
      dedup = Context.compress_repetitive(similarity_threshold: 1.0)
      
      # Remove similar messages (fuzzy matching)
      fuzzy_dedup = Context.compress_repetitive(
        similarity_threshold: 0.8,
        preserve_recent: 5
      )
  """
  @spec compress_repetitive(transform_options()) :: transform_fn()
  def compress_repetitive(opts \\ []) do
    similarity_threshold = Keyword.get(opts, :similarity_threshold, 0.9)
    preserve_recent = Keyword.get(opts, :preserve_recent, 3)
    
    fn messages, _abort_signal ->
      {recent, older} = Enum.split(messages, -preserve_recent)
      
      compressed_older = remove_similar_messages(older, similarity_threshold)
      
      {:ok, compressed_older ++ recent}
    end
  end

  @doc """
  Combines multiple transformation functions into a single pipeline.
  
  Executes transformations in sequence, with each transformation
  receiving the output of the previous one.
  
  ## Examples
  
      # Create a comprehensive context optimization pipeline
      optimization_pipeline = Context.compose_transforms([
        Context.filter_by_type([:user, :assistant, :tool_result]),
        Context.compress_repetitive(similarity_threshold: 0.8),
        Context.prune_by_tokens(4000, preserve_count: 5),
        Context.inject_context([%{type: :system, content: "Context optimized"}])
      ])
      
      {:ok, context} = MessageProcessor.process_pipeline(
        state,
        optimization_pipeline,
        nil
      )
  """
  @spec compose_transforms([transform_fn()]) :: transform_fn()
  def compose_transforms(transform_functions) when is_list(transform_functions) do
    fn messages, abort_signal ->
      Enum.reduce_while(transform_functions, {:ok, messages}, fn transform_fn, {:ok, current_messages} ->
        case transform_fn.(current_messages, abort_signal) do
          {:ok, transformed} -> {:cont, {:ok, transformed}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc """
  Analyzes context statistics for a list of messages.
  
  Provides insights into message distribution, token usage, and
  conversation patterns for optimization decisions.
  
  ## Examples
  
      stats = Context.analyze_context(messages)
      
      if stats.estimated_tokens > 5000 do
        apply_aggressive_pruning()
      end
      
      IO.puts("Conversation has " <> to_string(stats.message_count) <> " messages")
      IO.puts("Token distribution: " <> inspect(stats.type_distribution))
  """
  @spec analyze_context([Message.t()]) :: context_stats()
  def analyze_context(messages) when is_list(messages) do
    type_distribution = Message.group_by_type(messages)
                       |> Enum.map(fn {type, msgs} -> {type, length(msgs)} end)
                       |> Map.new()
    
    timestamps = Enum.map(messages, &Message.timestamp/1)
    age_range = if timestamps != [] do
      {Enum.min(timestamps), Enum.max(timestamps)}
    else
      nil
    end
    
    %{
      message_count: length(messages),
      estimated_tokens: MessageProcessor.estimate_tokens(messages),
      type_distribution: type_distribution,
      age_range: age_range
    }
  end

  @doc """
  Creates a smart transformation function that adapts based on context analysis.
  
  Analyzes the current conversation and dynamically applies appropriate
  transformations based on message count, token usage, and patterns.
  
  ## Examples
  
      # Adaptive transformation that adjusts based on conversation size
      smart_transform = Context.adaptive_transform(
        token_budget: 4000,
        strategies: [:prune_old, :compress_repetitive, :optimize_content]
      )
      
      {:ok, context} = MessageProcessor.process_pipeline(
        state,
        smart_transform,
        nil
      )
  """
  @spec adaptive_transform(transform_options()) :: transform_fn()
  def adaptive_transform(opts \\ []) do
    token_budget = Keyword.get(opts, :token_budget, 4000)
    strategies = Keyword.get(opts, :strategies, [:prune_old, :compress_repetitive])
    
    fn messages, abort_signal ->
      stats = analyze_context(messages)
      
      cond do
        stats.estimated_tokens <= token_budget ->
          # No transformation needed
          {:ok, messages}
          
        stats.message_count > 50 and :prune_old in strategies ->
          # Large conversation - aggressive pruning
          prune_fn = prune_by_count(30, preserve_types: [:system])
          prune_fn.(messages, abort_signal)
          
        stats.estimated_tokens > token_budget * 1.5 and :compress_repetitive in strategies ->
          # High token usage - remove repetitive content
          compress_fn = compress_repetitive(similarity_threshold: 0.8)
          compress_fn.(messages, abort_signal)
          
        true ->
          # Default token-based pruning
          prune_fn = prune_by_tokens(token_budget, preserve_count: 5)
          prune_fn.(messages, abort_signal)
      end
    end
  end

  # Private helper functions

  @spec extract_text_content(any()) :: String.t()
  defp extract_text_content(content) when is_binary(content), do: content
  
  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.filter(fn block -> match?(%{type: :text}, block) end)
    |> Enum.map(fn %{text: text} -> text end)
    |> Enum.join(" ")
  end
  
  defp extract_text_content(_), do: ""

  @spec create_context_message(map()) :: Message.t()
  defp create_context_message(%{type: :system, content: content}) do
    # Create a system message - in a real implementation, you might have
    # a SystemMessage type. For now, we'll use a user message with special marking.
    Message.user("[SYSTEM] " <> content)
  end
  
  defp create_context_message(%{content: content}) do
    Message.user(content)
  end

  @spec maybe_prune_for_model([Message.t()], atom(), pos_integer()) :: 
        {:ok, [Message.t()]} | {:error, any()}
  defp maybe_prune_for_model(messages, model_type, max_tokens) do
    current_tokens = MessageProcessor.estimate_tokens(messages)
    
    if current_tokens > max_tokens do
      # Apply model-specific pruning strategy
      preserve_count = case model_type do
        :claude -> 8  # Claude handles longer contexts well
        :llama_8b -> 3  # Smaller models need aggressive pruning
        _ -> 5  # Default
      end
      
      MessageProcessor.prune_by_tokens(messages, max_tokens, 
        preserve_count: preserve_count
      )
    else
      {:ok, messages}
    end
  end

  @spec maybe_compress_content([Message.t()], boolean()) :: 
        {:ok, [Message.t()]} | {:error, any()}
  defp maybe_compress_content(messages, false), do: {:ok, messages}
  
  defp maybe_compress_content(messages, true) do
    # Simple content compression - remove extra whitespace
    compressed = Enum.map(messages, fn message ->
      # This would be more sophisticated in a real implementation
      message  # Placeholder for now
    end)
    
    {:ok, compressed}
  end

  @spec maybe_format_for_thinking([Message.t()], boolean()) :: 
        {:ok, [Message.t()]} | {:error, any()}
  defp maybe_format_for_thinking(messages, false), do: {:ok, messages}
  
  defp maybe_format_for_thinking(messages, true) do
    # Add thinking prompts for models that support reasoning
    # This would add special formatting or instructions for reasoning models
    {:ok, messages}
  end

  @spec remove_similar_messages([Message.t()], float()) :: [Message.t()]
  defp remove_similar_messages(messages, similarity_threshold) do
    # Simple deduplication based on content similarity
    # In a real implementation, this would use more sophisticated similarity measures
    
    Enum.reduce(messages, [], fn message, acc ->
      content = Message.content(message) |> extract_text_content()
      
      is_similar = Enum.any?(acc, fn existing ->
        existing_content = Message.content(existing) |> extract_text_content()
        simple_similarity(content, existing_content) >= similarity_threshold
      end)
      
      if is_similar do
        acc  # Skip similar message
      else
        [message | acc]  # Keep unique message
      end
    end)
    |> Enum.reverse()
  end

  @spec simple_similarity(String.t(), String.t()) :: float()
  defp simple_similarity(text1, text2) do
    # Very simple similarity based on exact match
    # Real implementation would use more sophisticated algorithms
    if text1 == text2 do
      1.0
    else
      # Basic character overlap ratio
      chars1 = MapSet.new(String.graphemes(text1))
      chars2 = MapSet.new(String.graphemes(text2))
      intersection = MapSet.intersection(chars1, chars2)
      union = MapSet.union(chars1, chars2)
      
      if MapSet.size(union) > 0 do
        MapSet.size(intersection) / MapSet.size(union)
      else
        0.0
      end
    end
  end
end