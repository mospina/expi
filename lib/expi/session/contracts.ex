defmodule Expi.Session.Contracts do
  @moduledoc """
  Public Session-layer contracts for extensibility features.

  These structs provide stable metadata shapes for resource loading,
  command discovery, and diagnostics surfaced to clients.
  """

  defmodule ResourceDiagnostic do
    @moduledoc "Structured resource/extension diagnostic message."

    @type severity :: :info | :warning | :error | :collision

    @type t :: %__MODULE__{
            severity: severity(),
            message: String.t(),
            path: String.t() | nil,
            source: String.t() | nil
          }

    defstruct severity: :info, message: "", path: nil, source: nil
  end

  defmodule CommandInfo do
    @moduledoc "Command metadata for discovery APIs (CLI/server/RPC)."

    @type source :: :extension | :prompt | :skill
    @type location :: :user | :project | :path | nil

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            source: source(),
            location: location(),
            path: String.t() | nil,
            invokable: boolean()
          }

    defstruct name: "",
              description: nil,
              source: :extension,
              location: nil,
              path: nil,
              invokable: true
  end

  defmodule PromptTemplate do
    @moduledoc "Loaded prompt template metadata and content."

    @type source :: :user | :project | :path | :extension

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            content: String.t(),
            source: source(),
            file_path: String.t(),
            location: CommandInfo.location()
          }

    defstruct name: "",
              description: nil,
              content: "",
              source: :path,
              file_path: "",
              location: :path
  end

  defmodule Skill do
    @moduledoc "Loaded skill metadata and content."

    @type source :: :user | :project | :path | :extension

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            body: String.t(),
            source: source(),
            file_path: String.t(),
            base_dir: String.t(),
            location: CommandInfo.location(),
            disable_model_invocation: boolean()
          }

    defstruct name: "",
              description: "",
              body: "",
              source: :path,
              file_path: "",
              base_dir: "",
              location: :path,
              disable_model_invocation: false
  end
end
