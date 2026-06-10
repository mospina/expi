defmodule Expi.Session.BuiltinTools do
  @moduledoc """
  Built-in tool catalog for `Expi.Session`.

  Provides a small default set aligned with pi-coding-agent behavior.
  """

  alias Expi.Agent.Tool
  alias Expi.Agent.Types.AgentToolResult
  alias Expi.Session.Contracts.ResourceDiagnostic

  @default_names ["read", "bash", "edit", "write"]
  @optional_names ["grep", "find", "ls"]

  @spec default_names() :: [String.t()]
  def default_names, do: @default_names

  @spec all_names() :: [String.t()]
  def all_names, do: @default_names ++ @optional_names

  @spec fetch(String.t()) :: {:ok, Expi.Agent.Types.AgentTool.t()} | :error
  def fetch(name) do
    case Map.get(catalog(), name) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end

  @spec select([String.t()]) :: {[Expi.Agent.Types.AgentTool.t()], [ResourceDiagnostic.t()]}
  def select(names) when is_list(names) do
    Enum.reduce(names, {[], []}, fn name, {tools, diagnostics} ->
      case fetch(name) do
        {:ok, tool} ->
          {tools ++ [tool], diagnostics}

        :error ->
          diag = %ResourceDiagnostic{
            severity: :warning,
            message: "unknown built-in tool: #{name}",
            source: "builtin_tools"
          }

          {tools, diagnostics ++ [diag]}
      end
    end)
  end

  defp catalog do
    %{
      "read" => read_tool(),
      "write" => write_tool(),
      "edit" => edit_tool(),
      "bash" => bash_tool(),
      "grep" => grep_tool(),
      "find" => find_tool(),
      "ls" => ls_tool()
    }
  end

  defp read_tool do
    {:ok, tool} =
      Tool.text_tool(
        "read",
        "Read file contents from a path",
        %{type: :object, properties: %{path: %{type: :string}}, required: ["path"]},
        fn _id, params, _abort, _update ->
          case get_param(params, "path") do
            nil -> {:error, :missing_path}
            path -> read_path(path)
          end
        end
      )

    tool
  end

  defp write_tool do
    {:ok, tool} =
      Tool.text_tool(
        "write",
        "Write text content to a file path",
        %{
          type: :object,
          properties: %{path: %{type: :string}, content: %{type: :string}},
          required: ["path", "content"]
        },
        fn _id, params, _abort, _update ->
          case {get_param(params, "path"), get_param(params, "content")} do
            {nil, _} -> {:error, :missing_path}
            {_, nil} -> {:error, :missing_content}
            {path, content} -> write_content(path, content)
          end
        end
      )

    tool
  end

  defp edit_tool do
    {:ok, tool} =
      Tool.text_tool(
        "edit",
        "Replace exact text in a file",
        %{
          type: :object,
          properties: %{
            path: %{type: :string},
            old_text: %{type: :string},
            new_text: %{type: :string}
          },
          required: ["path", "old_text", "new_text"]
        },
        fn _id, params, _abort, _update ->
          path = get_param(params, "path")
          old_text = get_param(params, "old_text")
          new_text = get_param(params, "new_text")

          with {:ok, content} <- File.read(path),
               true <- is_binary(old_text),
               true <- String.contains?(content, old_text),
               replaced <- String.replace(content, old_text, new_text),
               :ok <- File.write(path, replaced) do
            {:ok, "edited #{path}"}
          else
            {:error, reason} -> {:ok, "edit failed: #{inspect(reason)}"}
            false -> {:ok, "edit failed: old_text not found"}
          end
        end
      )

    tool
  end

  defp bash_tool do
    {:ok, tool} =
      Tool.new(
        "bash",
        "Execute a shell command",
        %{type: :object, properties: %{command: %{type: :string}}, required: ["command"]},
        "bash",
        fn _id, params, _abort, _update ->
          command = get_param(params, "command")

          case command do
            nil ->
              {:error, :missing_command}

            _ ->
              {output, status} = System.cmd("bash", ["-lc", command], stderr_to_stdout: true)
              {:ok, AgentToolResult.text("exit=#{status}\n" <> output, %{status: status})}
          end
        end
      )

    tool
  end

  defp grep_tool do
    {:ok, tool} =
      Tool.text_tool(
        "grep",
        "Search file contents by regex",
        %{
          type: :object,
          properties: %{pattern: %{type: :string}, path: %{type: :string}},
          required: ["pattern"]
        },
        fn _id, params, _abort, _update ->
          pattern = get_param(params, "pattern") || ""
          path = get_param(params, "path") || "."

          {output, status} =
            System.cmd(
              "sh",
              ["-lc", "grep -R -n -- #{shell_escape(pattern)} #{shell_escape(path)}"],
              stderr_to_stdout: true
            )

          {:ok, "exit=#{status}\n" <> output}
        end
      )

    tool
  end

  defp find_tool do
    {:ok, tool} =
      Tool.text_tool(
        "find",
        "Find files by glob-like pattern",
        %{
          type: :object,
          properties: %{pattern: %{type: :string}, path: %{type: :string}},
          required: ["pattern"]
        },
        fn _id, params, _abort, _update ->
          pattern = get_param(params, "pattern") || "*"
          path = get_param(params, "path") || "."

          {output, status} =
            System.cmd("sh", ["-lc", "find #{shell_escape(path)} -name #{shell_escape(pattern)}"],
              stderr_to_stdout: true
            )

          {:ok, "exit=#{status}\n" <> output}
        end
      )

    tool
  end

  defp ls_tool do
    {:ok, tool} =
      Tool.text_tool(
        "ls",
        "List directory contents",
        %{type: :object, properties: %{path: %{type: :string}}},
        fn _id, params, _abort, _update ->
          path = get_param(params, "path") || "."
          {output, status} = System.cmd("ls", ["-la", path], stderr_to_stdout: true)
          {:ok, "exit=#{status}\n" <> output}
        end
      )

    tool
  end

  defp get_param(params, key) do
    Map.get(params, key) || Map.get(params, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(params, key)
  end

  defp read_path(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:ok, "read failed: #{inspect(reason)}"}
    end
  end

  defp write_content(path, content) do
    with :ok <- ensure_parent(path),
         :ok <- File.write(path, content) do
      {:ok, "wrote #{byte_size(content)} bytes to #{path}"}
    else
      {:error, reason} -> {:ok, "write failed: #{inspect(reason)}"}
    end
  end

  defp ensure_parent(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
