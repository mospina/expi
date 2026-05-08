defmodule Expi.Session.Extension do
  @moduledoc """
  Behaviour for Session extensions.

  Extensions return declarative registrations for commands, tools, and hooks.
  """

  @type command_spec :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          required(:handler) => (String.t(), any(), map() -> {:ok, any()} | {:error, any()})
        }

  @type hook_result :: :continue | {:transform, String.t(), list()} | {:handled, any()}

  @type registration :: %{
          optional(:commands) => [command_spec()],
          optional(:tools) => list(),
          optional(:hooks) => %{optional(atom()) => list()}
        }

  @callback register(map()) :: registration() | {:ok, registration()} | {:error, term()}
end
