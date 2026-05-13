defmodule Expi.Session do
  @moduledoc """
  Public Session API for Expi.

  Provides idiomatic Elixir session creation and composition over the existing
  AI and Agent modules.
  """

  alias Expi.Agent
  alias Expi.Agent.State, as: AgentStateOps
  alias Expi.Session.AgentSession
  alias Expi.Session.ExtensionRunner
  alias Expi.Session.FeatureFlags
  alias Expi.Session.Manager
  alias Expi.Session.ResourceLoader
  alias Expi.Session.ToolPolicy
  alias Expi.Types.Model

  @type create_session_result :: %{
          session: AgentSession.t(),
          model_fallback_message: String.t() | nil
        }

  @doc """
  Creates a new session runtime.

  ## Options

  - `:model` - `%Expi.Types.Model{}` (preferred)
  - `:provider` and `:model_id` - resolve model through `Expi.AI.get_model/2`
  - `:thinking_level` - default `:medium`
  - `:system_prompt` - default `""`
  - `:tools` - caller-provided tools appended after built-ins (default `[]`)
  - `:tool_mode` - `:default` | `:none` | `{:only, [name]}` for built-in selection
  - `:cwd` - default current working directory
  - `:session_dir` - optional explicit session dir
  - `:session_manager` - optional pre-built manager
  - `:scoped_models` - models for cycle operations
  - `:default_run_options` - options passed to `Expi.Agent.run_conversation/2`
  - `:continue_recent` - if true, resumes recent session in cwd/session_dir
  - `:open_session_path` - if set, opens an explicit session file
  - `:in_memory` - if true, disables file persistence
  - `:enable_resources` - enable resource loader features (prompts/skills)
  - `:enable_extensions` - enable extension runtime
  - `:extensions` - list of extension modules implementing `Expi.Session.Extension`
  - `:trusted_extensions` - optional allow-list of extension modules
  - `:prompt_paths` - additional prompt template paths
  - `:skill_paths` - additional skill paths
  """
  @spec create_session(map()) :: {:ok, create_session_result()} | {:error, term()}
  def create_session(options \\ %{}) do
    feature_flags = FeatureFlags.from_options(options)

    with {:ok, model, model_fallback_message} <- resolve_model(options),
         {:ok, manager} <- resolve_manager(options),
         {:ok, agent, builtin_tool_diagnostics} <- create_agent(model, options),
         {:ok, manager, agent} <- restore_or_initialize_session(manager, agent, options) do
      resource_loader =
        ResourceLoader.new(%{
          cwd: Map.get(options, :cwd, File.cwd!()),
          include_defaults: feature_flags.enable_resources,
          prompt_paths: Map.get(options, :prompt_paths, []),
          skill_paths: Map.get(options, :skill_paths, [])
        })

      extension_runner =
        ExtensionRunner.new(%{
          enabled: feature_flags.enable_extensions,
          extensions: Map.get(options, :extensions, []),
          trusted_modules: Map.get(options, :trusted_extensions, []),
          context: %{cwd: Map.get(options, :cwd, File.cwd!())}
        })

      agent = extension_runner |> ExtensionRunner.apply_tools(agent)

      session = %AgentSession{
        agent: agent,
        session_manager: manager,
        scoped_models: Map.get(options, :scoped_models, []),
        default_run_options: Map.get(options, :default_run_options, %{}),
        resource_loader: resource_loader,
        extension_runner: extension_runner,
        feature_flags: feature_flags,
        builtin_tool_diagnostics: builtin_tool_diagnostics
      }

      {:ok, %{session: session, model_fallback_message: model_fallback_message}}
    end
  end

  defp resolve_model(%{model: %Model{} = model}) do
    {:ok, model, nil}
  end

  defp resolve_model(options) do
    provider = Map.get(options, :provider)
    model_id = Map.get(options, :model_id)

    cond do
      is_binary(provider) and is_binary(model_id) ->
        case Expi.AI.get_model(provider, model_id) do
          {:ok, model} -> {:ok, model, nil}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :model_required}
    end
  end

  defp resolve_manager(%{session_manager: %Manager{} = manager}), do: {:ok, manager}

  defp resolve_manager(options) do
    cwd = Map.get(options, :cwd, File.cwd!())
    session_dir = Map.get(options, :session_dir)

    manager =
      cond do
        Map.get(options, :in_memory, false) -> Manager.in_memory(cwd)
        path = Map.get(options, :open_session_path) -> Manager.open(path, session_dir)
        Map.get(options, :continue_recent, false) -> Manager.continue_recent(cwd, session_dir)
        true -> Manager.create(cwd, session_dir)
      end

    {:ok, manager}
  end

  defp create_agent(model, options) do
    system_prompt = Map.get(options, :system_prompt, "")
    %{tools: tools, diagnostics: diagnostics} = ToolPolicy.resolve(options)
    thinking_level = normalize_thinking_level(Map.get(options, :thinking_level, :medium), model)

    case Agent.create(model, %{
           system_prompt: system_prompt,
           tools: tools,
           thinking_level: thinking_level
         }) do
      {:ok, agent} -> {:ok, agent, diagnostics}
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_or_initialize_session(manager, agent, options) do
    context = Manager.build_session_context(manager)

    has_existing = context.messages != []

    agent =
      if has_existing do
        agent
        |> AgentStateOps.set_messages(context.messages)
        |> AgentStateOps.set_thinking_level(
          normalize_thinking_level(context.thinking_level, agent.model)
        )
      else
        agent
      end

    if has_existing do
      {:ok, manager, agent}
    else
      {manager, _} = Manager.append_model_change(manager, agent.model.provider, agent.model.id)
      {manager, _} = Manager.append_thinking_level_change(manager, agent.thinking_level)

      if name = Map.get(options, :session_name) do
        {manager, _} = Manager.append_session_info(manager, name)
        {:ok, manager, agent}
      else
        {:ok, manager, agent}
      end
    end
  end

  defp normalize_thinking_level(level, model) do
    candidate =
      cond do
        is_binary(level) ->
          try do
            String.to_existing_atom(level)
          rescue
            ArgumentError -> :off
          end

        is_atom(level) ->
          level

        true ->
          :off
      end

    cond do
      not model.reasoning -> :off
      candidate in Expi.Agent.Types.thinking_levels() -> candidate
      true -> :medium
    end
  end
end
