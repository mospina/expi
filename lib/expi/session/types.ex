defmodule Expi.Session.Types do
  @moduledoc """
  Core types for Expi session lifecycle and persistence.

  Entry keys intentionally use pi-mono-compatible names (for example `parentId`
  and `firstKeptEntryId`) so serialized JSONL remains compatible.
  """

  @current_session_version 3

  @type thinking_level :: atom() | String.t()

  @type session_header :: %{
          required(:type) => :session,
          required(:version) => non_neg_integer(),
          required(:id) => String.t(),
          required(:timestamp) => String.t(),
          required(:cwd) => String.t(),
          optional(:parentSession) => String.t()
        }

  @type session_entry :: map()

  @type session_context :: %{
          messages: list(),
          thinking_level: thinking_level(),
          model: nil | %{provider: String.t(), model_id: String.t()}
        }

  @type session_info :: %{
          path: String.t(),
          id: String.t(),
          cwd: String.t(),
          name: String.t() | nil,
          parent_session_path: String.t() | nil,
          created: DateTime.t(),
          modified: DateTime.t(),
          message_count: non_neg_integer(),
          first_message: String.t(),
          all_messages_text: String.t()
        }

  @type agent_session_event ::
          Expi.Agent.Types.AgentEvent.t()
          | %{type: :auto_compaction_start, reason: :threshold | :overflow}
          | %{
              type: :auto_compaction_end,
              result: map() | nil,
              aborted: boolean(),
              will_retry: boolean(),
              error_message: String.t() | nil
            }
          | %{
              type: :auto_retry_start,
              attempt: pos_integer(),
              max_attempts: pos_integer(),
              delay_ms: non_neg_integer(),
              error_message: String.t()
            }
          | %{
              type: :auto_retry_end,
              success: boolean(),
              attempt: pos_integer(),
              final_error: String.t() | nil
            }

  @spec current_session_version() :: non_neg_integer()
  def current_session_version, do: @current_session_version
end
