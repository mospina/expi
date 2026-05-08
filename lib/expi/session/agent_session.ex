defmodule Expi.Session.AgentSession do
  @moduledoc """
  Session runtime wrapper around `Expi.Agent` and `Expi.Session.Manager`.

  This module composes Expi's existing Agent loop with durable session
  persistence and session-level lifecycle controls.
  """

  alias Expi.Agent
  alias Expi.Agent.State, as: AgentStateOps
  alias Expi.Agent.Types.AgentState
  alias Expi.Session.Contracts.CommandInfo
  alias Expi.Session.ExtensionRunner
  alias Expi.Session.FeatureFlags
  alias Expi.Session.Manager
  alias Expi.Session.ResourceLoader
  alias Expi.Types.{AssistantMessage, Model, TextContent, UserMessage}

  @type listener_ref :: reference()

  @type t :: %__MODULE__{
          agent: AgentState.t(),
          session_manager: Manager.t(),
          listeners: %{optional(listener_ref()) => (map() -> any())},
          scoped_models: [%{model: Model.t(), thinking_level: atom()}],
          auto_compaction_enabled: boolean(),
          auto_retry_enabled: boolean(),
          default_run_options: map(),
          resource_loader: ResourceLoader.t() | nil,
          extension_runner: ExtensionRunner.t() | nil,
          feature_flags: FeatureFlags.t() | nil
        }

  defstruct agent: nil,
            session_manager: nil,
            listeners: %{},
            scoped_models: [],
            auto_compaction_enabled: true,
            auto_retry_enabled: true,
            default_run_options: %{},
            resource_loader: nil,
            extension_runner: nil,
            feature_flags: nil

  @type prompt_options :: %{
          optional(:images) => list(),
          optional(:streaming_behavior) => :steer | :follow_up,
          optional(:run_conversation) => boolean(),
          optional(:run_options) => map(),
          optional(:expand_resources) => boolean()
        }

  @spec subscribe(t(), (map() -> any())) :: {t(), listener_ref()}
  def subscribe(%__MODULE__{} = session, listener) when is_function(listener, 1) do
    ref = make_ref()
    {%__MODULE__{session | listeners: Map.put(session.listeners, ref, listener)}, ref}
  end

  @spec unsubscribe(t(), listener_ref()) :: t()
  def unsubscribe(%__MODULE__{} = session, ref) do
    %__MODULE__{session | listeners: Map.delete(session.listeners, ref)}
  end

  @spec prompt(t(), String.t(), prompt_options()) :: {:ok, t()} | {:error, term()}
  def prompt(%__MODULE__{} = session, text, options \\ %{}) when is_binary(text) do
    run_conversation = Map.get(options, :run_conversation, true)
    expand_resources = Map.get(options, :expand_resources, true)

    with {:ok, session, dispatched_text, images} <-
           dispatch_input(session, text, Map.get(options, :images, []), expand_resources) do
      if dispatched_text == "" do
        {:ok, session}
      else
        session =
          emit_sync(session, %{
            type: :message_start,
            message: user_message(dispatched_text, %{images: images})
          })

        with {:ok, agent_after_user} <- Agent.send_message(session.agent, dispatched_text) do
          {session_manager, _} =
            persist_new_messages(
              session.session_manager,
              session.agent.messages,
              agent_after_user.messages
            )

          session = %__MODULE__{session | agent: agent_after_user, session_manager: session_manager}

          session =
            emit_sync(session, %{
              type: :message_end,
              message: List.last(agent_after_user.messages)
            })

          if run_conversation do
            run_opts = Map.merge(session.default_run_options, Map.get(options, :run_options, %{}))

            case Agent.run_conversation(agent_after_user, run_opts) do
              {:ok, final_agent} ->
                {manager, _} =
                  persist_new_messages(
                    session.session_manager,
                    agent_after_user.messages,
                    final_agent.messages
                  )

                session = %__MODULE__{session | agent: final_agent, session_manager: manager}

                session =
                  emit_sync(session, %{
                    type: :agent_end,
                    messages: final_agent.messages
                  })

                if assistant_turn_completed?(agent_after_user.messages, final_agent.messages) do
                  {:ok, session}
                else
                  {:error, :no_assistant_turn_attempted}
                end

              {:error, reason} ->
                {:error, reason}
            end
          else
            {:ok, session}
          end
        end
      end
    end
  end

  @spec reload_resources(t(), map()) :: t()
  def reload_resources(%__MODULE__{} = session, opts \\ %{}) do
    resource_loader =
      session.resource_loader
      |> case do
        nil ->
          ResourceLoader.new(%{
            cwd: Manager.get_cwd(session.session_manager),
            include_defaults: true,
            prompt_paths: Map.get(opts, :prompt_paths, []),
            skill_paths: Map.get(opts, :skill_paths, [])
          })

        loader ->
          if opts == %{} do
            ResourceLoader.reload(loader)
          else
            ResourceLoader.new(%{
              cwd: loader.cwd,
              include_defaults: loader.include_defaults,
              prompt_paths: Map.get(opts, :prompt_paths, loader.prompt_paths),
              skill_paths: Map.get(opts, :skill_paths, loader.skill_paths)
            })
          end
      end

    extension_runner =
      session.extension_runner
      |> case do
        nil ->
          ExtensionRunner.new(%{
            enabled: false,
            extensions: Map.get(opts, :extensions, []),
            trusted_modules: Map.get(opts, :trusted_extensions, []),
            context: %{cwd: Manager.get_cwd(session.session_manager)}
          })

        runner ->
          ExtensionRunner.new(%{
            enabled: runner.enabled,
            extensions: Map.get(opts, :extensions, []),
            trusted_modules: Map.get(opts, :trusted_extensions, MapSet.to_list(runner.trusted_modules)),
            context: %{cwd: Manager.get_cwd(session.session_manager)}
          })
      end

    agent = ExtensionRunner.apply_tools(extension_runner, session.agent)

    %__MODULE__{session | resource_loader: resource_loader, extension_runner: extension_runner, agent: agent}
  end

  @spec get_commands(t()) :: [CommandInfo.t()]
  def get_commands(%__MODULE__{} = session) do
    extension_commands =
      case session.extension_runner do
        nil -> []
        runner -> ExtensionRunner.command_infos(runner)
      end

    prompt_commands =
      case session.resource_loader do
        nil -> []
        loader -> ResourceLoader.prompt_commands(loader)
      end

    skill_commands =
      case session.resource_loader do
        nil -> []
        loader -> ResourceLoader.skill_commands(loader)
      end

    extension_commands ++ prompt_commands ++ skill_commands
  end

  @spec get_diagnostics(t()) :: list()
  def get_diagnostics(%__MODULE__{} = session) do
    resource_diagnostics =
      case session.resource_loader do
        nil -> []
        loader -> ResourceLoader.get_diagnostics(loader)
      end

    extension_diagnostics =
      case session.extension_runner do
        nil -> []
        runner -> ExtensionRunner.get_diagnostics(runner)
      end

    resource_diagnostics ++ extension_diagnostics
  end

  @spec steer(t(), String.t(), list()) :: {:ok, t()} | {:error, term()}
  def steer(%__MODULE__{} = session, text, _images \\ []) do
    session = emit_sync(session, %{type: :session_steer, text: text})

    with {:ok, updated_agent} <- Agent.add_steering(session.agent, text),
         {:ok, final_agent} <- Agent.run_conversation(updated_agent, session.default_run_options) do
      {manager, _} = persist_new_messages(session.session_manager, session.agent.messages, final_agent.messages)
      {:ok, %__MODULE__{session | agent: final_agent, session_manager: manager}}
    end
  end

  @spec follow_up(t(), String.t(), list()) :: {:ok, t()} | {:error, term()}
  def follow_up(%__MODULE__{} = session, text, _images \\ []) do
    session = emit_sync(session, %{type: :session_follow_up, text: text})

    with {:ok, updated_agent} <- Agent.add_follow_up(session.agent, text) do
      {:ok, %__MODULE__{session | agent: updated_agent}}
    end
  end

  @spec send_user_message(t(), String.t() | list(), map()) :: {:ok, t()} | {:error, term()}
  def send_user_message(%__MODULE__{} = session, content, opts \\ %{}) do
    {text, images} = normalize_content(content)
    prompt(session, text, Map.merge(opts, %{images: images}))
  end

  @spec new_session(t(), map()) :: {:ok, t()}
  def new_session(%__MODULE__{} = session, opts \\ %{}) do
    manager = Manager.new_session(session.session_manager, opts)

    agent =
      session.agent
      |> Agent.reset()
      |> AgentStateOps.set_messages([])

    {manager, _} = Manager.append_model_change(manager, agent.model.provider, agent.model.id)
    {manager, _} = Manager.append_thinking_level_change(manager, agent.thinking_level)

    {:ok, %__MODULE__{session | agent: agent, session_manager: manager}}
  end

  @spec switch_session(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def switch_session(%__MODULE__{} = session, path) do
    manager = Manager.open(path, Manager.get_session_dir(session.session_manager))
    context = Manager.build_session_context(manager)

    agent =
      session.agent
      |> Agent.reset()
      |> AgentStateOps.set_messages(context.messages)
      |> AgentStateOps.set_thinking_level(normalize_thinking_level(context.thinking_level))

    {:ok, %__MODULE__{session | agent: agent, session_manager: manager}}
  rescue
    error -> {:error, error}
  end

  @spec set_model(t(), Model.t()) :: t()
  def set_model(%__MODULE__{} = session, %Model{} = model) do
    updated_agent = %{session.agent | model: model}
    {manager, _} = Manager.append_model_change(session.session_manager, model.provider, model.id)
    %__MODULE__{session | agent: updated_agent, session_manager: manager}
  end

  @spec cycle_model(t(), :forward | :backward) :: {:ok, t(), map()} | {:error, :no_models}
  def cycle_model(%__MODULE__{} = session, direction \\ :forward) do
    scoped = session.scoped_models

    if length(scoped) <= 1 do
      {:error, :no_models}
    else
      current_index =
        Enum.find_index(scoped, fn %{model: model} ->
          model.provider == session.agent.model.provider and model.id == session.agent.model.id
        end) || 0

      next_index =
        case direction do
          :forward -> rem(current_index + 1, length(scoped))
          :backward -> rem(current_index - 1 + length(scoped), length(scoped))
        end

      %{model: next_model, thinking_level: next_thinking} = Enum.at(scoped, next_index)

      session =
        session
        |> set_model(next_model)
        |> set_thinking_level(next_thinking)

      {:ok, session, %{model: next_model, thinking_level: next_thinking, is_scoped: true}}
    end
  end

  @spec set_thinking_level(t(), atom() | String.t()) :: t()
  def set_thinking_level(%__MODULE__{} = session, level) do
    normalized = normalize_thinking_level(level)
    updated_agent = AgentStateOps.set_thinking_level(session.agent, normalized)
    {manager, _} = Manager.append_thinking_level_change(session.session_manager, normalized)
    %__MODULE__{session | agent: updated_agent, session_manager: manager}
  end

  @spec set_auto_compaction_enabled(t(), boolean()) :: t()
  def set_auto_compaction_enabled(%__MODULE__{} = session, enabled) do
    %__MODULE__{session | auto_compaction_enabled: enabled}
  end

  @spec set_auto_retry_enabled(t(), boolean()) :: t()
  def set_auto_retry_enabled(%__MODULE__{} = session, enabled) do
    %__MODULE__{session | auto_retry_enabled: enabled}
  end

  @spec clear_queue(t()) :: {t(), %{steering: list(), follow_up: list()}}
  def clear_queue(%__MODULE__{} = session) do
    {session, %{steering: [], follow_up: []}}
  end

  @spec get_steering_messages(t()) :: list()
  def get_steering_messages(_session), do: []

  @spec get_follow_up_messages(t()) :: list()
  def get_follow_up_messages(_session), do: []

  @spec compact(t(), String.t() | nil) :: {:ok, t(), map()} | {:error, term()}
  def compact(%__MODULE__{} = session, custom_instructions \\ nil) do
    entries = Manager.get_branch(session.session_manager)

    message_entries = Enum.filter(entries, fn e -> Map.get(e, :type) == :message end)

    if length(message_entries) < 4 do
      {:error, :nothing_to_compact}
    else
      keep_count = 4
      cutoff_index = max(length(message_entries) - keep_count, 0)
      older = Enum.take(message_entries, cutoff_index)
      kept = Enum.drop(message_entries, cutoff_index)

      first_kept_id =
        case kept do
          [first | _] -> Map.get(first, :id)
          _ -> Map.get(List.last(message_entries), :id)
        end

      summary = build_compaction_summary(older, custom_instructions)
      tokens_before = estimate_tokens(older)

      session = emit_sync(session, %{type: :auto_compaction_start, reason: :threshold})

      {manager, _} =
        Manager.append_compaction(
          session.session_manager,
          summary,
          first_kept_id,
          tokens_before,
          %{strategy: :heuristic},
          false
        )

      context = Manager.build_session_context(manager)
      updated_agent = AgentStateOps.set_messages(session.agent, context.messages)
      session = %__MODULE__{session | session_manager: manager, agent: updated_agent}

      result = %{
        summary: summary,
        first_kept_entry_id: first_kept_id,
        tokens_before: tokens_before
      }

      session =
        emit_sync(session, %{
          type: :auto_compaction_end,
          result: result,
          aborted: false,
          will_retry: false
        })

      {:ok, session, result}
    end
  end

  @spec branch(t(), String.t()) :: t()
  def branch(%__MODULE__{} = session, entry_id) do
    manager = Manager.branch(session.session_manager, entry_id)
    context = Manager.build_session_context(manager)

    updated_agent =
      session.agent
      |> AgentStateOps.set_messages(context.messages)
      |> AgentStateOps.set_thinking_level(normalize_thinking_level(context.thinking_level))

    %__MODULE__{session | session_manager: manager, agent: updated_agent}
  end

  @spec branch_with_summary(t(), String.t() | nil, String.t()) :: t()
  def branch_with_summary(%__MODULE__{} = session, entry_id, summary) do
    {manager, _} = Manager.branch_with_summary(session.session_manager, entry_id, summary)
    context = Manager.build_session_context(manager)
    updated_agent = AgentStateOps.set_messages(session.agent, context.messages)
    %__MODULE__{session | session_manager: manager, agent: updated_agent}
  end

  @spec session_file(t()) :: String.t() | nil
  def session_file(%__MODULE__{session_manager: manager}), do: Manager.get_session_file(manager)

  @spec session_id(t()) :: String.t()
  def session_id(%__MODULE__{session_manager: manager}), do: Manager.get_session_id(manager)

  @spec session_name(t()) :: String.t() | nil
  def session_name(%__MODULE__{session_manager: manager}), do: Manager.get_session_name(manager)

  @spec state(t()) :: AgentState.t()
  def state(%__MODULE__{agent: agent}), do: agent

  @spec model(t()) :: Model.t() | nil
  def model(%__MODULE__{agent: %{model: model}}), do: model

  @spec thinking_level(t()) :: atom()
  def thinking_level(%__MODULE__{agent: %{thinking_level: level}}), do: level

  @spec messages(t()) :: list()
  def messages(%__MODULE__{agent: %{messages: messages}}), do: messages

  @spec is_streaming(t()) :: boolean()
  def is_streaming(%__MODULE__{agent: %{is_streaming: is_streaming}}), do: is_streaming

  @spec auto_compaction_enabled?(t()) :: boolean()
  def auto_compaction_enabled?(%__MODULE__{auto_compaction_enabled: enabled}), do: enabled

  @spec auto_retry_enabled?(t()) :: boolean()
  def auto_retry_enabled?(%__MODULE__{auto_retry_enabled: enabled}), do: enabled

  @spec session_manager(t()) :: Manager.t()
  def session_manager(%__MODULE__{session_manager: manager}), do: manager

  defp dispatch_input(%__MODULE__{} = session, text, images, expand_resources) do
    with {:ok, session, text} <- maybe_execute_extension_command(session, text),
         {:ok, text, images} <- maybe_emit_input_hooks(session, text, images),
         {:ok, text} <- maybe_expand_skill_command(session, text, expand_resources),
         {:ok, text} <- maybe_expand_prompt_template(session, text, expand_resources) do
      {:ok, session, text, images}
    else
      {:error, {:command_handled, updated_session}} -> {:ok, updated_session, "", images}
      {:error, {:input_handled, _result}} -> {:ok, session, "", images}
      other -> other
    end
  end

  defp maybe_execute_extension_command(session, text) do
    case session.extension_runner do
      nil ->
        {:ok, session, text}

      runner ->
        case ExtensionRunner.execute_command(runner, text, session, %{cwd: Manager.get_cwd(session.session_manager)}) do
          {:handled, updated_session} -> {:error, {:command_handled, updated_session}}
          :not_found -> {:ok, session, text}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_emit_input_hooks(session, text, images) do
    case session.extension_runner do
      nil ->
        {:ok, text, images}

      runner ->
        case ExtensionRunner.emit_input(runner, text, images, %{cwd: Manager.get_cwd(session.session_manager)}) do
          {:continue, transformed_text, transformed_images} -> {:ok, transformed_text, transformed_images}
          {:handled, result} -> {:error, {:input_handled, result}}
        end
    end
  end

  defp maybe_expand_skill_command(_session, text, false), do: {:ok, text}

  defp maybe_expand_skill_command(session, text, true) do
    case session.resource_loader do
      nil -> {:ok, text}
      loader -> {:ok, ResourceLoader.expand_skill_command(text, loader)}
    end
  end

  defp maybe_expand_prompt_template(_session, text, false), do: {:ok, text}

  defp maybe_expand_prompt_template(session, text, true) do
    case session.resource_loader do
      nil -> {:ok, text}
      loader -> {:ok, ResourceLoader.expand_prompt_template(text, loader)}
    end
  end

  defp emit(%__MODULE__{} = session, event) do
    Enum.each(session.listeners, fn {_ref, listener} ->
      try do
        listener.(event)
      rescue
        _ -> :ok
      end
    end)

    {:ok, session}
  end

  defp emit_sync(session, event) do
    {:ok, session} = emit(session, event)
    session
  end

  defp user_message(text, options) do
    text_blocks = [%TextContent{type: :text, text: text}]
    blocks = text_blocks ++ Map.get(options, :images, [])

    %UserMessage{role: :user, content: blocks, timestamp: System.system_time(:millisecond)}
  end

  defp persist_new_messages(manager, before_messages, after_messages) do
    new_messages = Enum.drop(after_messages, length(before_messages))

    Enum.reduce(new_messages, {manager, []}, fn msg, {acc_manager, ids} ->
      if persistable_role?(Map.get(msg, :role)) do
        {acc_manager, id} = Manager.append_message(acc_manager, msg)
        {acc_manager, [id | ids]}
      else
        {acc_manager, ids}
      end
    end)
  end

  defp persistable_role?(role), do: role in [:user, :assistant, :tool_result]

  defp normalize_content(content) when is_binary(content), do: {content, []}

  defp normalize_content(content) when is_list(content) do
    {text, images} =
      Enum.reduce(content, {[], []}, fn
        %{type: :text, text: text}, {texts, images} -> {[text | texts], images}
        %TextContent{text: text}, {texts, images} -> {[text | texts], images}
        image, {texts, images} -> {texts, [image | images]}
      end)

    {Enum.reverse(text) |> Enum.join("\n"), Enum.reverse(images)}
  end

  defp normalize_thinking_level(level) when is_binary(level) do
    try do
      atom = String.to_existing_atom(level)
      if atom in Expi.Agent.Types.thinking_levels(), do: atom, else: :off
    rescue
      ArgumentError -> :off
    end
  end

  defp normalize_thinking_level(level) when is_atom(level) do
    if level in Expi.Agent.Types.thinking_levels(), do: level, else: :off
  end

  defp build_compaction_summary(entries, custom_instructions) do
    body =
      entries
      |> Enum.map(fn entry ->
        message = Map.get(entry, :message, %{})
        role = Map.get(message, :role, :unknown)
        text = message_text(message)
        "- #{role}: #{String.slice(text, 0, 240)}"
      end)
      |> Enum.join("\n")

    prefix =
      if is_binary(custom_instructions), do: "Instructions: #{custom_instructions}\n\n", else: ""

    prefix <> "Compacted conversation summary:\n" <> body
  end

  defp message_text(%{content: content}) when is_binary(content), do: content

  defp message_text(%{content: content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{type: :text, text: text} -> [text]
      %TextContent{text: text} -> [text]
      _ -> []
    end)
    |> Enum.join(" ")
  end

  defp message_text(%AssistantMessage{content: content}) do
    content
    |> Enum.flat_map(fn
      %{type: :text, text: text} -> [text]
      _ -> []
    end)
    |> Enum.join(" ")
  end

  defp message_text(_), do: ""

  defp estimate_tokens(entries) do
    entries
    |> Enum.map(fn e ->
      Map.get(e, :message) |> message_text() |> String.split(~r/\s+/, trim: true) |> length()
    end)
    |> Enum.sum()
  end

  defp assistant_turn_completed?(before_messages, after_messages) do
    new_messages = Enum.drop(after_messages, length(before_messages))

    Enum.any?(new_messages, fn
      %{role: :assistant} -> true
      _ -> false
    end)
  end
end
