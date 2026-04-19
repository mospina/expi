defmodule Expi.Session.TypesTest do
  use ExUnit.Case, async: true

  alias Expi.Session.Types

  test "current session version is aligned with pi-mono schema version" do
    assert Types.current_session_version() == 3
  end
end
