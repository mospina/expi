defmodule Expi.Session.ToolPolicy do
  @moduledoc """
  Tool selection policy for Session startup.
  """

  alias Expi.Session.BuiltinTools
  alias Expi.Session.Contracts.ResourceDiagnostic

  @type tool_mode :: :default | :none | {:only, [String.t()]}

  @spec resolve(map()) :: %{tools: list(), diagnostics: [ResourceDiagnostic.t()]}
  def resolve(options) do
    tool_mode = Map.get(options, :tool_mode, :default)
    caller_tools = Map.get(options, :tools, [])

    {builtin_tools, diagnostics} =
      case tool_mode do
        :default -> BuiltinTools.select(BuiltinTools.default_names())
        :none -> {[], []}
        {:only, names} when is_list(names) -> BuiltinTools.select(names)
        other ->
          diag = %ResourceDiagnostic{severity: :warning, message: "invalid tool_mode: #{inspect(other)}; using :default", source: "tool_policy"}
          {tools, diags} = BuiltinTools.select(BuiltinTools.default_names())
          {tools, [diag | diags]}
      end

    %{tools: builtin_tools ++ caller_tools, diagnostics: diagnostics}
  end
end
