defmodule Expi.Session.Manager do
  @moduledoc """
  Append-only session manager with branch-aware traversal and JSONL persistence.

  Persistence format is compatible with pi-mono session JSONL shape:
  - Header: `%{type: :session, version, id, timestamp, cwd, parentSession?}`
  - Entries include `id`, `parentId`, and `timestamp`
  """

  alias Expi.Session.Types
  alias Expi.Types.{ImageContent, TextContent, UserMessage}

  @type entry_id :: String.t()

  @type t :: %__MODULE__{
          session_id: String.t(),
          session_file: String.t() | nil,
          session_dir: String.t(),
          cwd: String.t(),
          persist: boolean(),
          file_entries: [map()],
          by_id: %{optional(String.t()) => map()},
          labels_by_id: %{optional(String.t()) => String.t()},
          leaf_id: String.t() | nil
        }

  defstruct session_id: "",
            session_file: nil,
            session_dir: "",
            cwd: "",
            persist: true,
            file_entries: [],
            by_id: %{},
            labels_by_id: %{},
            leaf_id: nil

  @spec current_session_version() :: non_neg_integer()
  def current_session_version, do: Types.current_session_version()

  @spec create(String.t(), String.t() | nil) :: t()
  def create(cwd, session_dir \\ nil) do
    dir = session_dir || default_session_dir(cwd)

    %__MODULE__{cwd: cwd, session_dir: dir, persist: true}
    |> ensure_session_dir()
    |> new_session()
  end

  @spec open(String.t(), String.t() | nil) :: t()
  def open(path, session_dir \\ nil) do
    entries = load_entries_from_file(path)
    header = Enum.find(entries, fn e -> Map.get(e, :type) == :session end)
    cwd = (header && Map.get(header, :cwd)) || File.cwd!()
    dir = session_dir || Path.dirname(Path.expand(path))

    %__MODULE__{cwd: cwd, session_dir: dir, persist: true}
    |> ensure_session_dir()
    |> set_session_file(path)
  end

  @spec continue_recent(String.t(), String.t() | nil) :: t()
  def continue_recent(cwd, session_dir \\ nil) do
    dir = session_dir || default_session_dir(cwd)

    case find_most_recent_session(dir) do
      nil -> create(cwd, dir)
      path -> open(path, dir)
    end
  end

  @spec in_memory(String.t()) :: t()
  def in_memory(cwd \\ File.cwd!()) do
    %__MODULE__{cwd: cwd, session_dir: "", persist: false}
    |> new_session()
  end

  @spec list(String.t(), String.t() | nil) :: [Types.session_info()]
  def list(cwd, session_dir \\ nil) do
    dir = session_dir || default_session_dir(cwd)

    dir
    |> list_session_files()
    |> Enum.map(&build_session_info/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&DateTime.to_unix(&1.modified, :millisecond), :desc)
  end

  @spec list_all() :: [Types.session_info()]
  def list_all do
    sessions_root = Path.join(agent_dir(), "sessions")

    if File.dir?(sessions_root) do
      sessions_root
      |> File.ls!()
      |> Enum.map(&Path.join(sessions_root, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(fn dir ->
        dir
        |> list_session_files()
        |> Enum.map(&build_session_info/1)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&DateTime.to_unix(&1.modified, :millisecond), :desc)
    else
      []
    end
  end

  @spec new_session(t(), map()) :: t()
  def new_session(%__MODULE__{} = manager, opts \\ %{}) do
    session_id = uuid()
    timestamp = now_iso()

    header = %{
      type: :session,
      version: current_session_version(),
      id: session_id,
      timestamp: timestamp,
      cwd: manager.cwd,
      parentSession: Map.get(opts, :parentSession)
    }

    session_file =
      if manager.persist do
        Path.join(manager.session_dir, "#{safe_timestamp(timestamp)}_#{session_id}.jsonl")
      else
        nil
      end

    %__MODULE__{
      manager
      | session_id: session_id,
        session_file: session_file,
        file_entries: [header],
        by_id: %{},
        labels_by_id: %{},
        leaf_id: nil
    }
    |> maybe_rewrite_file()
  end

  @spec set_session_file(t(), String.t()) :: t()
  def set_session_file(%__MODULE__{} = manager, session_file) do
    path = Path.expand(session_file)

    if File.exists?(path) do
      entries = load_entries_from_file(path)

      manager = %__MODULE__{manager | session_file: path, file_entries: entries}

      case Enum.find(entries, fn e -> Map.get(e, :type) == :session end) do
        nil ->
          %__MODULE__{manager | session_file: path} |> new_session()

        header ->
          manager
          |> Map.put(:session_id, Map.get(header, :id, uuid()))
          |> rebuild_index()
      end
    else
      %__MODULE__{manager | session_file: path} |> new_session()
    end
  end

  @spec append_message(t(), map()) :: {t(), entry_id()}
  def append_message(manager, message) do
    entry = base_entry(manager, :message) |> Map.put(:message, message)
    append_entry(manager, entry)
  end

  @spec append_thinking_level_change(t(), String.t() | atom()) :: {t(), entry_id()}
  def append_thinking_level_change(manager, level) do
    entry =
      base_entry(manager, :thinking_level_change) |> Map.put(:thinkingLevel, to_string(level))

    append_entry(manager, entry)
  end

  @spec append_model_change(t(), String.t(), String.t()) :: {t(), entry_id()}
  def append_model_change(manager, provider, model_id) do
    entry =
      base_entry(manager, :model_change) |> Map.merge(%{provider: provider, modelId: model_id})

    append_entry(manager, entry)
  end

  @spec append_compaction(t(), String.t(), String.t(), non_neg_integer(), any(), boolean() | nil) ::
          {t(), entry_id()}
  def append_compaction(
        manager,
        summary,
        first_kept_entry_id,
        tokens_before,
        details \\ nil,
        from_hook \\ nil
      ) do
    entry =
      base_entry(manager, :compaction)
      |> Map.merge(%{
        summary: summary,
        firstKeptEntryId: first_kept_entry_id,
        tokensBefore: tokens_before,
        details: details,
        fromHook: from_hook
      })

    append_entry(manager, entry)
  end

  @spec append_custom_entry(t(), String.t(), any()) :: {t(), entry_id()}
  def append_custom_entry(manager, custom_type, data \\ nil) do
    entry = base_entry(manager, :custom) |> Map.merge(%{customType: custom_type, data: data})
    append_entry(manager, entry)
  end

  @spec append_custom_message_entry(t(), String.t(), String.t() | list(), boolean(), any()) ::
          {t(), entry_id()}
  def append_custom_message_entry(manager, custom_type, content, display, details \\ nil) do
    entry =
      base_entry(manager, :custom_message)
      |> Map.merge(%{
        customType: custom_type,
        content: content,
        display: display,
        details: details
      })

    append_entry(manager, entry)
  end

  @spec append_label_change(t(), String.t(), String.t() | nil) :: {t(), entry_id()}
  def append_label_change(%__MODULE__{} = manager, target_id, label) do
    if Map.has_key?(manager.by_id, target_id) do
      entry = base_entry(manager, :label) |> Map.merge(%{targetId: target_id, label: label})
      {updated, id} = append_entry(manager, entry)
      %__MODULE__{} = updated

      updated =
        if is_binary(label) and String.trim(label) != "" do
          %__MODULE__{updated | labels_by_id: Map.put(updated.labels_by_id, target_id, label)}
        else
          %__MODULE__{updated | labels_by_id: Map.delete(updated.labels_by_id, target_id)}
        end

      {updated, id}
    else
      raise ArgumentError, "Entry #{target_id} not found"
    end
  end

  @spec append_session_info(t(), String.t()) :: {t(), entry_id()}
  def append_session_info(manager, name) do
    entry = base_entry(manager, :session_info) |> Map.put(:name, String.trim(name))
    append_entry(manager, entry)
  end

  @spec branch_with_summary(t(), String.t() | nil, String.t(), any(), boolean() | nil) ::
          {t(), entry_id()}
  def branch_with_summary(manager, branch_from_id, summary, details \\ nil, from_hook \\ nil) do
    manager =
      cond do
        is_nil(branch_from_id) ->
          %__MODULE__{manager | leaf_id: nil}

        Map.has_key?(manager.by_id, branch_from_id) ->
          %__MODULE__{manager | leaf_id: branch_from_id}

        true ->
          raise ArgumentError, "Entry #{branch_from_id} not found"
      end

    %__MODULE__{} = manager

    entry =
      base_entry(manager, :branch_summary)
      |> Map.merge(%{
        fromId: branch_from_id || "root",
        summary: summary,
        details: details,
        fromHook: from_hook
      })

    append_entry(manager, entry)
  end

  @spec branch(t(), String.t()) :: t()
  def branch(%__MODULE__{} = manager, branch_from_id) do
    if Map.has_key?(manager.by_id, branch_from_id) do
      %__MODULE__{manager | leaf_id: branch_from_id}
    else
      raise ArgumentError, "Entry #{branch_from_id} not found"
    end
  end

  @spec reset_leaf(t()) :: t()
  def reset_leaf(%__MODULE__{} = manager), do: %__MODULE__{manager | leaf_id: nil}

  @spec get_leaf_id(t()) :: String.t() | nil
  def get_leaf_id(%__MODULE__{leaf_id: leaf_id}), do: leaf_id

  @spec get_leaf_entry(t()) :: map() | nil
  def get_leaf_entry(%__MODULE__{leaf_id: nil}), do: nil
  def get_leaf_entry(%__MODULE__{leaf_id: leaf_id, by_id: by_id}), do: Map.get(by_id, leaf_id)

  @spec get_entry(t(), String.t()) :: map() | nil
  def get_entry(%__MODULE__{by_id: by_id}, id), do: Map.get(by_id, id)

  @spec get_children(t(), String.t()) :: [map()]
  def get_children(%__MODULE__{by_id: by_id}, parent_id) do
    by_id
    |> Map.values()
    |> Enum.filter(&(Map.get(&1, :parentId) == parent_id))
  end

  @spec get_label(t(), String.t()) :: String.t() | nil
  def get_label(%__MODULE__{labels_by_id: labels_by_id}, id), do: Map.get(labels_by_id, id)

  @spec get_branch(t(), String.t() | nil) :: [map()]
  def get_branch(%__MODULE__{} = manager, from_id \\ nil) do
    start_id = from_id || manager.leaf_id

    unwind_branch(manager.by_id, start_id, [])
  end

  @spec build_session_context(t()) :: Types.session_context()
  def build_session_context(%__MODULE__{} = manager) do
    build_session_context_from_entries(get_entries(manager), manager.leaf_id, manager.by_id)
  end

  @spec get_header(t()) :: map() | nil
  def get_header(%__MODULE__{file_entries: file_entries}) do
    Enum.find(file_entries, fn e -> Map.get(e, :type) == :session end)
  end

  @spec get_entries(t()) :: [map()]
  def get_entries(%__MODULE__{file_entries: file_entries}) do
    Enum.reject(file_entries, fn e -> Map.get(e, :type) == :session end)
  end

  @spec get_tree(t()) :: [map()]
  def get_tree(%__MODULE__{} = manager) do
    entries = get_entries(manager)

    node_map =
      entries
      |> Enum.map(fn entry ->
        {Map.fetch!(entry, :id),
         %{entry: entry, children: [], label: Map.get(manager.labels_by_id, Map.get(entry, :id))}}
      end)
      |> Map.new()

    {node_map, roots} =
      Enum.reduce(entries, {node_map, []}, fn entry, {acc_nodes, acc_roots} ->
        node = Map.fetch!(acc_nodes, Map.fetch!(entry, :id))

        parent_id = Map.get(entry, :parentId)

        cond do
          is_nil(parent_id) or parent_id == Map.get(entry, :id) ->
            {acc_nodes, [node | acc_roots]}

          Map.has_key?(acc_nodes, parent_id) ->
            parent = Map.fetch!(acc_nodes, parent_id)
            updated_parent = %{parent | children: [node | parent.children]}
            {Map.put(acc_nodes, parent_id, updated_parent), acc_roots}

          true ->
            {acc_nodes, [node | acc_roots]}
        end
      end)

    roots
    |> Enum.map(&materialize_node(&1, node_map))
    |> Enum.sort_by(fn n -> Map.get(n.entry, :timestamp, "") end)
  end

  @spec get_session_name(t()) :: String.t() | nil
  def get_session_name(%__MODULE__{} = manager) do
    manager
    |> get_entries()
    |> Enum.reverse()
    |> Enum.find_value(fn entry ->
      if Map.get(entry, :type) == :session_info do
        Map.get(entry, :name)
      end
    end)
  end

  @spec get_session_id(t()) :: String.t()
  def get_session_id(%__MODULE__{session_id: session_id}), do: session_id

  @spec get_session_file(t()) :: String.t() | nil
  def get_session_file(%__MODULE__{session_file: session_file}), do: session_file

  @spec get_session_dir(t()) :: String.t()
  def get_session_dir(%__MODULE__{session_dir: session_dir}), do: session_dir

  @spec get_cwd(t()) :: String.t()
  def get_cwd(%__MODULE__{cwd: cwd}), do: cwd

  @spec persisted?(t()) :: boolean()
  def persisted?(%__MODULE__{persist: persist}), do: persist

  @spec load_entries_from_file(String.t()) :: [map()]
  def load_entries_from_file(file_path) do
    if File.exists?(file_path) do
      file_path
      |> File.stream!([], :line)
      |> Stream.map(&String.trim/1)
      |> Stream.filter(&(&1 != ""))
      |> Stream.map(&decode_entry/1)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  @spec find_most_recent_session(String.t()) :: String.t() | nil
  def find_most_recent_session(session_dir) do
    session_dir
    |> list_session_files()
    |> Enum.map(fn path -> {path, File.stat!(path).mtime} end)
    |> Enum.sort_by(fn {_path, mtime} -> mtime end, {:desc, DateTime})
    |> List.first()
    |> case do
      {path, _} -> path
      nil -> nil
    end
  rescue
    _ -> nil
  end

  @spec build_session_context_from_entries(
          [map()],
          String.t() | nil,
          %{optional(String.t()) => map()} | nil
        ) ::
          Types.session_context()
  def build_session_context_from_entries(entries, leaf_id \\ nil, by_id \\ nil) do
    by_id = by_id || Map.new(entries, fn e -> {Map.get(e, :id), e} end)

    case find_leaf(entries, by_id, leaf_id) do
      nil ->
        %{messages: [], thinking_level: "off", model: nil}

      leaf ->
        path = unwind_branch(by_id, Map.get(leaf, :id), [])
        {thinking_level, model, compaction} = reduce_context_meta(path)
        messages = build_messages_from_path(path, compaction)
        %{messages: messages, thinking_level: thinking_level, model: model}
    end
  end

  defp find_leaf(entries, _by_id, nil), do: List.last(entries)
  defp find_leaf(_entries, by_id, leaf_id), do: Map.get(by_id, leaf_id)

  defp reduce_context_meta(path) do
    Enum.reduce(path, {"off", nil, nil}, fn entry, acc -> reduce_context_entry(entry, acc) end)
  end

  defp reduce_context_entry(entry, {lvl, mdl, comp}) do
    case Map.get(entry, :type) do
      :thinking_level_change ->
        {Map.get(entry, :thinkingLevel, lvl), mdl, comp}

      :model_change ->
        {lvl, %{provider: Map.get(entry, :provider), model_id: Map.get(entry, :modelId)}, comp}

      :message ->
        update_model_from_message(entry, {lvl, mdl, comp})

      :compaction ->
        {lvl, mdl, entry}

      _ ->
        {lvl, mdl, comp}
    end
  end

  defp update_model_from_message(entry, {lvl, mdl, comp}) do
    case Map.get(entry, :message) do
      %{role: :assistant, provider: provider, model: model_id} ->
        {lvl, %{provider: provider, model_id: model_id}, comp}

      _ ->
        {lvl, mdl, comp}
    end
  end

  # Internal helpers

  defp append_entry(%__MODULE__{} = manager, entry) do
    updated = %__MODULE__{
      manager
      | file_entries: manager.file_entries ++ [entry],
        by_id: Map.put(manager.by_id, Map.get(entry, :id), entry),
        leaf_id: Map.get(entry, :id)
    }

    updated =
      if Map.get(entry, :type) == :label do
        label = Map.get(entry, :label)
        target_id = Map.get(entry, :targetId)

        if is_binary(label) and String.trim(label) != "" do
          %__MODULE__{updated | labels_by_id: Map.put(updated.labels_by_id, target_id, label)}
        else
          %__MODULE__{updated | labels_by_id: Map.delete(updated.labels_by_id, target_id)}
        end
      else
        updated
      end

    {maybe_rewrite_file(updated), Map.get(entry, :id)}
  end

  defp base_entry(manager, type) do
    %{
      type: type,
      id: generate_short_id(Map.keys(manager.by_id) |> MapSet.new()),
      parentId: manager.leaf_id,
      timestamp: now_iso()
    }
  end

  defp default_session_dir(cwd) do
    safe_path =
      cwd
      |> String.replace_leading("/", "")
      |> String.replace(~r|[/\\:]|, "-")
      |> then(&"--#{&1}--")

    dir = Path.join([agent_dir(), "sessions", safe_path])
    File.mkdir_p!(dir)
    dir
  end

  defp agent_dir do
    System.get_env("PI_CODING_AGENT_DIR") || Path.join(System.user_home!(), ".pi/agent")
  end

  defp ensure_session_dir(%__MODULE__{persist: true, session_dir: session_dir} = manager) do
    File.mkdir_p!(session_dir)
    manager
  end

  defp ensure_session_dir(manager), do: manager

  defp maybe_rewrite_file(
         %__MODULE__{persist: true, session_file: session_file, file_entries: entries} = manager
       )
       when is_binary(session_file) do
    content = entries |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
    File.mkdir_p!(Path.dirname(session_file))
    File.write!(session_file, content <> "\n")
    manager
  end

  defp maybe_rewrite_file(manager), do: manager

  defp rebuild_index(%__MODULE__{} = manager) do
    {by_id, labels_by_id, leaf_id} =
      manager.file_entries
      |> Enum.reject(&(Map.get(&1, :type) == :session))
      |> Enum.reduce({%{}, %{}, nil}, &reduce_index_entry/2)

    %__MODULE__{manager | by_id: by_id, labels_by_id: labels_by_id, leaf_id: leaf_id}
  end

  defp reduce_index_entry(entry, {idx, labels, _leaf}) do
    id = Map.get(entry, :id)
    updated_labels = maybe_update_label_index(labels, entry)
    {Map.put(idx, id, entry), updated_labels, id}
  end

  defp maybe_update_label_index(labels, %{type: :label} = entry) do
    label = Map.get(entry, :label)
    target = Map.get(entry, :targetId)

    if is_binary(label) and String.trim(label) != "" do
      Map.put(labels, target, label)
    else
      Map.delete(labels, target)
    end
  end

  defp maybe_update_label_index(labels, _entry), do: labels

  defp decode_entry(line) do
    case Jason.decode(line, keys: :atoms) do
      {:ok, map} -> map
      _ -> nil
    end
  end

  defp list_session_files(dir) do
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&valid_session_file?/1)
    else
      []
    end
  rescue
    _ -> []
  end

  defp valid_session_file?(path) do
    case File.open(path, [:read]) do
      {:ok, io} ->
        io
        |> IO.read(:line)
        |> valid_session_header_line?()
        |> tap(fn _ -> File.close(io) end)

      _ ->
        false
    end
  end

  defp valid_session_header_line?(:eof), do: false

  defp valid_session_header_line?(data) do
    case Jason.decode(String.trim(data), keys: :atoms) do
      {:ok, %{type: :session, id: id}} when is_binary(id) -> true
      _ -> false
    end
  end

  defp build_session_info(path) do
    entries = load_entries_from_file(path)
    header = Enum.find(entries, fn e -> Map.get(e, :type) == :session end)

    with %{id: id, timestamp: timestamp} <- header,
         {:ok, created, _} <- DateTime.from_iso8601(timestamp),
         {:ok, stat} <- File.stat(path) do
      message_entries = Enum.filter(entries, fn e -> Map.get(e, :type) == :message end)

      texts =
        message_entries
        |> Enum.flat_map(fn e -> message_text_chunks(Map.get(e, :message)) end)

      first_message = texts |> Enum.find("(no messages)", fn txt -> String.trim(txt) != "" end)

      modified = DateTime.from_naive!(stat.mtime, "Etc/UTC")

      %{
        path: path,
        id: id,
        cwd: Map.get(header, :cwd, ""),
        name: latest_session_name(entries),
        parent_session_path: Map.get(header, :parentSession),
        created: created,
        modified: modified,
        message_count: length(message_entries),
        first_message: first_message,
        all_messages_text: Enum.join(texts, " ")
      }
    else
      _ -> nil
    end
  end

  defp latest_session_name(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find_value(fn entry ->
      if Map.get(entry, :type) == :session_info do
        Map.get(entry, :name)
      end
    end)
  end

  defp unwind_branch(_by_id, nil, path), do: path

  defp unwind_branch(by_id, current_id, path) do
    case Map.get(by_id, current_id) do
      nil -> path
      entry -> unwind_branch(by_id, Map.get(entry, :parentId), [entry | path])
    end
  end

  defp build_messages_from_path(path, compaction) do
    append_message = fn entry, acc ->
      case Map.get(entry, :type) do
        :message -> acc ++ [Map.get(entry, :message)]
        :custom_message -> acc ++ [custom_message_as_user(entry)]
        :branch_summary -> acc ++ [branch_summary_message(entry)]
        _ -> acc
      end
    end

    if is_nil(compaction) do
      Enum.reduce(path, [], append_message)
    else
      compaction_id = Map.get(compaction, :id)
      first_kept = Map.get(compaction, :firstKeptEntryId)
      pre = Enum.take_while(path, fn e -> Map.get(e, :id) != compaction_id end)
      post = Enum.drop_while(path, fn e -> Map.get(e, :id) != compaction_id end) |> Enum.drop(1)

      kept_pre =
        pre
        |> Enum.drop_while(fn e -> Map.get(e, :id) != first_kept end)

      [compaction_summary_message(compaction)] ++
        Enum.reduce(kept_pre, [], append_message) ++
        Enum.reduce(post, [], append_message)
    end
  end

  defp custom_message_as_user(entry) do
    content =
      case Map.get(entry, :content) do
        value when is_binary(value) -> value
        value when is_list(value) -> value
        other -> inspect(other)
      end

    %UserMessage{
      role: :user,
      content: content,
      timestamp: parse_timestamp_ms(Map.get(entry, :timestamp))
    }
  end

  defp branch_summary_message(entry) do
    %UserMessage{
      role: :user,
      content:
        "[Branch Summary from #{Map.get(entry, :fromId)}]\n\n#{Map.get(entry, :summary, "")}",
      timestamp: parse_timestamp_ms(Map.get(entry, :timestamp))
    }
  end

  defp compaction_summary_message(entry) do
    %UserMessage{
      role: :user,
      content: "[Compaction Summary]\n\n#{Map.get(entry, :summary, "")}",
      timestamp: parse_timestamp_ms(Map.get(entry, :timestamp))
    }
  end

  defp parse_timestamp_ms(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> System.system_time(:millisecond)
    end
  end

  defp parse_timestamp_ms(_), do: System.system_time(:millisecond)

  defp message_text_chunks(%{content: content}) when is_binary(content), do: [content]

  defp message_text_chunks(%{content: content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{type: :text, text: text} -> [text]
      %TextContent{text: text} -> [text]
      %ImageContent{} -> []
      _ -> []
    end)
  end

  defp message_text_chunks(_), do: []

  defp materialize_node(node, node_map) do
    %{
      node
      | children:
          node.children
          |> Enum.map(fn child ->
            child_id = Map.get(child.entry, :id)
            materialize_node(Map.fetch!(node_map, child_id), node_map)
          end)
          |> Enum.sort_by(fn c -> Map.get(c.entry, :timestamp, "") end)
    }
  end

  defp generate_short_id(existing_ids) do
    candidate = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    if MapSet.member?(existing_ids, candidate) do
      generate_short_id(existing_ids)
    else
      candidate
    end
  end

  defp uuid do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp safe_timestamp(timestamp) do
    String.replace(timestamp, ~r/[:.]/, "-")
  end
end
