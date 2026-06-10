defmodule Expi.Session.ResourceLoader do
  @moduledoc """
  Session resource discovery and loading for prompts and skills.

  Supports deterministic discovery with source metadata and diagnostics.
  """

  alias Expi.Session.Contracts.{CommandInfo, PromptTemplate, ResourceDiagnostic, Skill}

  @type source_path :: %{path: String.t(), source: atom(), location: CommandInfo.location()}

  @type t :: %__MODULE__{
          cwd: String.t(),
          agent_dir: String.t(),
          include_defaults: boolean(),
          prompt_paths: [String.t()],
          skill_paths: [String.t()],
          prompts: [PromptTemplate.t()],
          skills: [Skill.t()],
          diagnostics: [ResourceDiagnostic.t()]
        }

  defstruct cwd: "",
            agent_dir: "",
            include_defaults: true,
            prompt_paths: [],
            skill_paths: [],
            prompts: [],
            skills: [],
            diagnostics: []

  @spec new(map()) :: t()
  def new(opts \\ %{}) do
    loader = %__MODULE__{
      cwd: Map.get(opts, :cwd, File.cwd!()),
      agent_dir: Map.get(opts, :agent_dir, default_agent_dir()),
      include_defaults: Map.get(opts, :include_defaults, true),
      prompt_paths: Map.get(opts, :prompt_paths, []),
      skill_paths: Map.get(opts, :skill_paths, [])
    }

    reload(loader)
  end

  @spec reload(t()) :: t()
  def reload(%__MODULE__{} = loader) do
    prompt_sources = discover_prompt_sources(loader)
    skill_sources = discover_skill_sources(loader)

    {prompts, prompt_diagnostics} = load_prompts(prompt_sources)
    {skills, skill_diagnostics} = load_skills(skill_sources)

    %__MODULE__{
      loader
      | prompts: prompts,
        skills: skills,
        diagnostics: prompt_diagnostics ++ skill_diagnostics
    }
  end

  @spec get_prompts(t()) :: [PromptTemplate.t()]
  def get_prompts(%__MODULE__{prompts: prompts}), do: prompts

  @spec get_skills(t()) :: [Skill.t()]
  def get_skills(%__MODULE__{skills: skills}), do: skills

  @spec get_diagnostics(t()) :: [ResourceDiagnostic.t()]
  def get_diagnostics(%__MODULE__{diagnostics: diagnostics}), do: diagnostics

  @spec prompt_commands(t()) :: [CommandInfo.t()]
  def prompt_commands(%__MODULE__{} = loader) do
    loader.prompts
    |> Enum.map(fn prompt ->
      %CommandInfo{
        name: prompt.name,
        description: prompt.description,
        source: :prompt,
        location: prompt.location,
        path: prompt.file_path,
        invokable: true
      }
    end)
  end

  @spec skill_commands(t()) :: [CommandInfo.t()]
  def skill_commands(%__MODULE__{} = loader) do
    loader.skills
    |> Enum.map(fn skill ->
      %CommandInfo{
        name: "skill:" <> skill.name,
        description: skill.description,
        source: :skill,
        location: skill.location,
        path: skill.file_path,
        invokable: true
      }
    end)
  end

  @spec expand_prompt_template(String.t(), t()) :: String.t()
  def expand_prompt_template(text, %__MODULE__{} = loader) when is_binary(text) do
    if String.starts_with?(text, "/") do
      {name, args} = parse_slash_command(text)

      case Enum.find(loader.prompts, &(&1.name == name)) do
        nil ->
          text

        template ->
          substitute_prompt_args(template.content, args)
      end
    else
      text
    end
  end

  @spec expand_skill_command(String.t(), t()) :: String.t()
  def expand_skill_command(text, %__MODULE__{} = loader) when is_binary(text) do
    if String.starts_with?(text, "/skill:") do
      {name, args} = parse_skill_command(text)

      case Enum.find(loader.skills, &(&1.name == name)) do
        nil ->
          text

        skill ->
          skill_block =
            "<skill name=\"#{skill.name}\" location=\"#{skill.file_path}\">\n" <>
              "References are relative to #{skill.base_dir}.\n\n" <>
              String.trim(skill.body) <>
              "\n</skill>"

          if args == "", do: skill_block, else: skill_block <> "\n\n" <> args
      end
    else
      text
    end
  end

  defp discover_prompt_sources(%__MODULE__{} = loader) do
    defaults =
      if loader.include_defaults do
        [
          %{path: Path.join(loader.agent_dir, "prompts"), source: :user, location: :user},
          %{
            path: Path.join([loader.cwd, config_dir_name(), "prompts"]),
            source: :project,
            location: :project
          }
        ]
      else
        []
      end

    explicit =
      loader.prompt_paths
      |> Enum.map(fn p ->
        %{path: resolve_path(loader.cwd, p), source: :path, location: :path}
      end)

    dedupe_sources(defaults ++ explicit)
  end

  defp discover_skill_sources(%__MODULE__{} = loader) do
    defaults =
      if loader.include_defaults do
        [
          %{path: Path.join(loader.agent_dir, "skills"), source: :user, location: :user},
          %{
            path: Path.join([loader.cwd, config_dir_name(), "skills"]),
            source: :project,
            location: :project
          }
        ] ++ compatibility_skill_sources(loader)
      else
        []
      end

    explicit =
      loader.skill_paths
      |> Enum.map(fn p ->
        %{path: resolve_path(loader.cwd, p), source: :path, location: :path}
      end)

    dedupe_sources(defaults ++ explicit)
  end

  defp compatibility_skill_sources(loader) do
    user_agents = %{
      path: Path.join(System.user_home!(), ".agents/skills"),
      source: :user,
      location: :user
    }

    ancestors =
      ancestor_dirs(loader.cwd)
      |> Enum.map(fn dir ->
        %{path: Path.join(dir, ".agents/skills"), source: :project, location: :project}
      end)

    [user_agents | ancestors]
  end

  defp load_prompts(sources) do
    sources
    |> Enum.reduce({[], [], MapSet.new()}, &reduce_prompt_source/2)
    |> finalize_resource_accumulator()
  end

  defp reduce_prompt_source(source, acc) do
    source
    |> prompt_source_files()
    |> Enum.reduce(acc, fn file, inner_acc ->
      file
      |> load_prompt_file(source)
      |> merge_resource_result(:prompt, file, source, inner_acc)
    end)
  end

  defp prompt_source_files(%{path: path}) do
    cond do
      not File.exists?(path) ->
        []

      File.dir?(path) ->
        path
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.join(path, &1))

      true ->
        [path]
    end
  end

  defp load_prompt_file(file, source) do
    case File.read(file) do
      {:ok, raw} ->
        {frontmatter, body} = split_frontmatter(raw)
        name = Path.basename(file, ".md")
        description = Map.get(frontmatter, "description") || first_non_empty_line(body)

        {:ok,
         %PromptTemplate{
           name: name,
           description: description,
           content: body,
           source: source.source,
           file_path: file,
           location: source.location
         }}

      {:error, reason} ->
        {:error, "failed to read prompt file: #{inspect(reason)}"}
    end
  end

  defp load_skills(sources) do
    sources
    |> Enum.reduce({[], [], MapSet.new()}, &reduce_skill_source/2)
    |> finalize_resource_accumulator()
  end

  defp reduce_skill_source(source, acc) do
    source
    |> skill_source_files()
    |> Enum.reduce(acc, fn file, inner_acc ->
      file
      |> load_skill_file(source)
      |> merge_resource_result(:skill, file, source, inner_acc)
    end)
  end

  defp skill_source_files(%{path: path}) do
    cond do
      not File.exists?(path) -> []
      File.dir?(path) -> collect_skill_files(path)
      String.ends_with?(path, ".md") -> [path]
      true -> []
    end
  end

  defp load_skill_file(file, source) do
    case File.read(file) do
      {:ok, raw} ->
        build_skill_from_raw(raw, file, source)

      {:error, reason} ->
        {:error, "failed to read skill file: #{inspect(reason)}"}
    end
  end

  defp build_skill_from_raw(raw, file, source) do
    {frontmatter, body} = split_frontmatter(raw)
    base_dir = Path.dirname(file)
    name = Map.get(frontmatter, "name") || Path.basename(base_dir)
    description = Map.get(frontmatter, "description")

    if is_nil(description) or String.trim(description) == "" do
      {:error, "skill description is required"}
    else
      {:ok,
       %Skill{
         name: name,
         description: description,
         body: body,
         source: source.source,
         file_path: file,
         base_dir: base_dir,
         location: source.location,
         disable_model_invocation: parse_bool(Map.get(frontmatter, "disable-model-invocation"))
       }}
    end
  end

  defp merge_resource_result({:ok, resource}, kind, file, source, {items, diagnostics, names}) do
    if MapSet.member?(names, resource.name) do
      {items, diagnostics ++ [collision_diagnostic(kind, resource.name, file, source)], names}
    else
      {items ++ [resource], diagnostics, MapSet.put(names, resource.name)}
    end
  end

  defp merge_resource_result({:error, reason}, _kind, file, source, {items, diagnostics, names}) do
    {items, diagnostics ++ [warning_diagnostic(reason, file, source)], names}
  end

  defp collision_diagnostic(:prompt, name, file, source) do
    %ResourceDiagnostic{
      severity: :collision,
      message: "prompt name collision: /#{name}",
      path: file,
      source: Atom.to_string(source.source)
    }
  end

  defp collision_diagnostic(:skill, name, file, source) do
    %ResourceDiagnostic{
      severity: :collision,
      message: "skill name collision: #{name}",
      path: file,
      source: Atom.to_string(source.source)
    }
  end

  defp warning_diagnostic(reason, file, source) do
    %ResourceDiagnostic{
      severity: :warning,
      message: reason,
      path: file,
      source: Atom.to_string(source.source)
    }
  end

  defp finalize_resource_accumulator({resources, diagnostics, _names}),
    do: {resources, diagnostics}

  defp collect_skill_files(dir) do
    do_collect_skill_files(dir, true)
  end

  defp do_collect_skill_files(dir, include_root_files) do
    entries =
      dir
      |> File.ls!()
      |> Enum.reject(&String.starts_with?(&1, "."))

    Enum.flat_map(entries, fn entry ->
      full = Path.join(dir, entry)

      cond do
        File.dir?(full) ->
          do_collect_skill_files(full, false)

        include_root_files and String.ends_with?(entry, ".md") ->
          [full]

        not include_root_files and entry == "SKILL.md" ->
          [full]

        true ->
          []
      end
    end)
  end

  defp split_frontmatter(content) do
    regex = ~r/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/

    case Regex.run(regex, content) do
      [_, fm, body] -> {parse_frontmatter_map(fm), body}
      _ -> {%{}, content}
    end
  end

  defp parse_frontmatter_map(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [k, v] -> Map.put(acc, String.trim(k), trim_quotes(String.trim(v)))
        _ -> acc
      end
    end)
  end

  defp trim_quotes(value) do
    value
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp parse_bool(value) when is_boolean(value), do: value
  defp parse_bool(value) when is_binary(value), do: String.downcase(value) == "true"
  defp parse_bool(_), do: false

  defp first_non_empty_line(body) do
    body
    |> String.split("\n")
    |> Enum.find("", fn line -> String.trim(line) != "" end)
    |> String.trim()
  end

  defp parse_slash_command(text) do
    text = String.trim_leading(text, "/")

    case String.split(text, " ", parts: 2) do
      [name, args] -> {name, args}
      [name] -> {name, ""}
    end
  end

  defp parse_skill_command(text) do
    command = String.trim_leading(text, "/skill:")

    case String.split(command, " ", parts: 2) do
      [name, args] -> {name, String.trim(args)}
      [name] -> {name, ""}
    end
  end

  defp substitute_prompt_args(content, args_string) do
    args = parse_command_args(args_string)

    content
    |> replace_positional_args(args)
    |> String.replace("$@", Enum.join(args, " "))
    |> String.replace("$ARGUMENTS", Enum.join(args, " "))
  end

  defp replace_positional_args(content, args) do
    Regex.replace(~r/\$(\d+)/, content, fn _, num ->
      case Integer.parse(num) do
        {index, _} -> Enum.at(args, index - 1) || ""
        _ -> ""
      end
    end)
  end

  defp parse_command_args(args_string) do
    args_string
    |> String.trim()
    |> case do
      "" -> []
      other -> Regex.scan(~r/"([^"]*)"|'([^']*)'|(\S+)/, other)
    end
    |> Enum.map(fn
      [_, a, "", ""] -> a
      [_, "", b, ""] -> b
      [_, "", "", c] -> c
      _ -> ""
    end)
  end

  defp dedupe_sources(sources) do
    sources
    |> Enum.reduce({[], MapSet.new()}, fn src, {acc, seen} ->
      expanded = Path.expand(src.path)

      if MapSet.member?(seen, expanded) do
        {acc, seen}
      else
        {[Map.put(src, :path, expanded) | acc], MapSet.put(seen, expanded)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp resolve_path(cwd, path) do
    expanded =
      case path do
        "~" -> System.user_home!()
        <<"~/", rest::binary>> -> Path.join(System.user_home!(), rest)
        other -> other
      end

    if Path.type(expanded) == :absolute, do: expanded, else: Path.expand(expanded, cwd)
  end

  defp ancestor_dirs(start) do
    do_ancestor_dirs(Path.expand(start), [])
  end

  defp do_ancestor_dirs(dir, acc) do
    parent = Path.dirname(dir)

    if parent == dir do
      Enum.reverse([dir | acc])
    else
      do_ancestor_dirs(parent, [dir | acc])
    end
  end

  defp config_dir_name do
    Application.get_env(:expi, :config_dir_name, ".pi")
  end

  defp default_agent_dir do
    System.get_env("EXPI_CODING_AGENT_DIR") ||
      System.get_env("PI_CODING_AGENT_DIR") ||
      Path.join([System.user_home!(), config_dir_name(), "agent"])
  end
end
