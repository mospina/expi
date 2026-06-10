defmodule Expi.Session.ExtensionRunner do
  @moduledoc """
  Runtime for Session extensions (commands, tools, hooks).

  Designed for deterministic registration, explicit diagnostics, and
  compatibility with long-running BEAM processes.
  """

  alias Expi.Agent.State, as: AgentStateOps
  alias Expi.Session.Contracts.{CommandInfo, ResourceDiagnostic}

  @type extension_module :: module()

  @type command :: %{
          name: String.t(),
          description: String.t() | nil,
          handler: (String.t(), any(), map() -> {:ok, any()} | {:error, any()}),
          extension: extension_module()
        }

  @type t :: %__MODULE__{
          enabled: boolean(),
          trusted_modules: MapSet.t(module()),
          commands: %{optional(String.t()) => command()},
          tools: list(),
          hooks: %{optional(atom()) => list()},
          diagnostics: [ResourceDiagnostic.t()]
        }

  defstruct enabled: false,
            trusted_modules: MapSet.new(),
            commands: %{},
            tools: [],
            hooks: %{},
            diagnostics: []

  @spec new(map()) :: t()
  def new(opts \\ %{}) do
    %__MODULE__{
      enabled: Map.get(opts, :enabled, false),
      trusted_modules: MapSet.new(Map.get(opts, :trusted_modules, []))
    }
    |> load_extensions(Map.get(opts, :extensions, []), Map.get(opts, :context, %{}))
  end

  @spec load_extensions(t(), [extension_module()], map()) :: t()
  def load_extensions(%__MODULE__{} = runner, extensions, context \\ %{}) do
    if not runner.enabled do
      if extensions != [] do
        diag = %ResourceDiagnostic{
          severity: :warning,
          message: "extensions configured but extension runtime is disabled",
          source: "extensions"
        }

        %__MODULE__{runner | diagnostics: runner.diagnostics ++ [diag]}
      else
        runner
      end
    else
      Enum.reduce(extensions, runner, fn extension, acc ->
        register_extension(acc, extension, context)
      end)
    end
  end

  @spec execute_command(t(), String.t(), any(), map()) ::
          {:handled, any()} | :not_found | {:error, term()}
  def execute_command(%__MODULE__{} = runner, text, session, context \\ %{}) do
    with true <- String.starts_with?(text, "/"),
         {command_name, args} <- parse_slash_command(text),
         %{handler: handler} <- Map.get(runner.commands, command_name) do
      case handler.(args, session, context) do
        {:ok, updated_session} -> {:handled, updated_session}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_command_result, other}}
      end
    else
      false -> :not_found
      nil -> :not_found
    end
  end

  @spec emit_input(t(), String.t(), list(), map()) ::
          {:continue, String.t(), list()} | {:handled, any()}
  def emit_input(%__MODULE__{} = runner, text, images, context \\ %{}) do
    hooks = Map.get(runner.hooks, :input, [])

    Enum.reduce_while(hooks, {:continue, text, images}, fn hook,
                                                           {:continue, current_text,
                                                            current_images} ->
      case hook.(current_text, current_images, context) do
        :continue -> {:cont, {:continue, current_text, current_images}}
        {:transform, new_text, new_images} -> {:cont, {:continue, new_text, new_images}}
        {:handled, result} -> {:halt, {:handled, result}}
        _ -> {:cont, {:continue, current_text, current_images}}
      end
    end)
  end

  @spec apply_tools(t(), any()) :: any()
  def apply_tools(%__MODULE__{} = runner, agent_state) do
    existing = AgentStateOps.get_tools(agent_state)
    AgentStateOps.update_tools(agent_state, existing ++ runner.tools)
  end

  @spec command_infos(t()) :: [CommandInfo.t()]
  def command_infos(%__MODULE__{} = runner) do
    runner.commands
    |> Map.values()
    |> Enum.map(fn command ->
      %CommandInfo{
        name: command.name,
        description: command.description,
        source: :extension,
        location: nil,
        path: inspect(command.extension),
        invokable: true
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  @spec get_diagnostics(t()) :: [ResourceDiagnostic.t()]
  def get_diagnostics(%__MODULE__{diagnostics: diagnostics}), do: diagnostics

  defp register_extension(%__MODULE__{} = runner, extension_module, context) do
    cond do
      not Code.ensure_loaded?(extension_module) ->
        add_diag(
          runner,
          :error,
          "extension module not available: #{inspect(extension_module)}",
          inspect(extension_module)
        )

      not function_exported?(extension_module, :register, 1) ->
        add_diag(
          runner,
          :error,
          "extension missing register/1: #{inspect(extension_module)}",
          inspect(extension_module)
        )

      MapSet.size(runner.trusted_modules) > 0 and
          not MapSet.member?(runner.trusted_modules, extension_module) ->
        add_diag(
          runner,
          :warning,
          "extension skipped (not trusted): #{inspect(extension_module)}",
          inspect(extension_module)
        )

      true ->
        case extension_module.register(context) do
          {:ok, registration} ->
            apply_registration(runner, extension_module, registration)

          registration when is_map(registration) ->
            apply_registration(runner, extension_module, registration)

          {:error, reason} ->
            add_diag(
              runner,
              :error,
              "extension registration failed: #{inspect(reason)}",
              inspect(extension_module)
            )

          other ->
            add_diag(
              runner,
              :error,
              "invalid extension registration: #{inspect(other)}",
              inspect(extension_module)
            )
        end
    end
  end

  defp apply_registration(runner, extension_module, registration) do
    commands = normalize_commands(Map.get(registration, :commands, []), extension_module)
    tools = Map.get(registration, :tools, [])
    hooks = Map.get(registration, :hooks, %{})

    {runner, _} =
      Enum.reduce(commands, {runner, MapSet.new(Map.keys(runner.commands))}, fn command,
                                                                                {acc, seen} ->
        %__MODULE__{} = acc

        if MapSet.member?(seen, command.name) do
          {
            add_diag(
              acc,
              :collision,
              "command collision: /#{command.name}",
              inspect(extension_module)
            ),
            seen
          }
        else
          {
            %{acc | commands: Map.put(acc.commands, command.name, command)},
            MapSet.put(seen, command.name)
          }
        end
      end)

    merged_hooks =
      Map.merge(runner.hooks, hooks, fn _k, existing, incoming ->
        existing ++ incoming
      end)

    %__MODULE__{} = runner
    %{runner | tools: runner.tools ++ tools, hooks: merged_hooks}
  end

  defp normalize_commands(commands, extension_module) do
    Enum.flat_map(commands, fn
      %{name: name, handler: handler} = command
      when is_binary(name) and is_function(handler, 3) ->
        [
          %{
            name: name,
            description: Map.get(command, :description),
            handler: handler,
            extension: extension_module
          }
        ]

      _ ->
        []
    end)
  end

  defp parse_slash_command(text) do
    stripped = String.trim_leading(text, "/")

    case String.split(stripped, " ", parts: 2) do
      [name, args] -> {name, args}
      [name] -> {name, ""}
    end
  end

  defp add_diag(%__MODULE__{} = runner, severity, message, source) do
    diag = %ResourceDiagnostic{severity: severity, message: message, source: source}
    %__MODULE__{runner | diagnostics: runner.diagnostics ++ [diag]}
  end
end
