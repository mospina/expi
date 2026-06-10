defmodule Expi.SessionExtensibilityTest do
  use ExUnit.Case

  alias Expi.Session
  alias Expi.Session.AgentSession
  alias Expi.Session.ExtensionRunner
  alias Expi.Types.{Cost, Model, TextContent}

  defmodule TestExtension do
    @behaviour Expi.Session.Extension

    def register(_ctx) do
      %{
        commands: [
          %{
            name: "echo",
            description: "Echo command",
            handler: fn args, session, _ctx ->
              AgentSession.prompt(session, "[echo] " <> args, %{
                run_conversation: false,
                expand_resources: false
              })
            end
          }
        ],
        hooks: %{
          input: [
            fn text, images, _ctx ->
              if String.starts_with?(text, "!!up ") do
                {:transform, String.upcase(String.replace_prefix(text, "!!up ", "")), images}
              else
                :continue
              end
            end
          ]
        }
      }
    end
  end

  defmodule DisabledExtension do
    @behaviour Expi.Session.Extension

    def register(_ctx), do: raise("register/1 should not be called when extensions are disabled")
  end

  test "resource loader expands prompt templates and skills" do
    cwd = temp_cwd!("resources")
    File.mkdir_p!(Path.join(cwd, ".pi/prompts"))
    File.mkdir_p!(Path.join(cwd, ".pi/skills/release-notes"))

    File.write!(Path.join(cwd, ".pi/prompts/review.md"), "Review:\n$ARGUMENTS")

    File.write!(
      Path.join(cwd, ".pi/skills/release-notes/SKILL.md"),
      """
      ---
      name: release-notes
      description: Release notes helper
      ---
      # Release Notes
      Include highlights.
      """
    )

    {:ok, %{session: session}} =
      Session.create_session(%{
        model: demo_model(),
        in_memory: true,
        cwd: cwd,
        enable_resources: true
      })

    {:ok, session} =
      AgentSession.prompt(session, "/review alpha beta", %{run_conversation: false})

    {:ok, session} =
      AgentSession.prompt(session, "/skill:release-notes prepare v1", %{run_conversation: false})

    user_messages = Enum.filter(AgentSession.messages(session), &(&1.role == :user))
    [first, second | _] = user_messages

    assert extract_text(first) =~ "Review:"
    assert extract_text(first) =~ "alpha beta"

    assert extract_text(second) =~ "<skill name=\"release-notes\""
    assert extract_text(second) =~ "prepare v1"
  end

  test "extension commands and input hooks are applied before agent turn" do
    {:ok, %{session: session}} =
      Session.create_session(%{
        model: demo_model(),
        in_memory: true,
        enable_resources: true,
        enable_extensions: true,
        trusted_extensions: [TestExtension],
        extensions: [TestExtension]
      })

    {:ok, session} = AgentSession.prompt(session, "/echo hello", %{run_conversation: false})
    {:ok, session} = AgentSession.prompt(session, "!!up make me loud", %{run_conversation: false})

    user_messages = Enum.filter(AgentSession.messages(session), &(&1.role == :user))
    [first, second | _] = user_messages

    assert extract_text(first) == "[echo] hello"
    assert extract_text(second) == "MAKE ME LOUD"
  end

  test "disabled extension runtime records diagnostics when extensions are configured" do
    runner = ExtensionRunner.new(%{enabled: false, extensions: [DisabledExtension]})

    diagnostics = ExtensionRunner.get_diagnostics(runner)

    assert Enum.any?(diagnostics, fn d ->
             d.source == "extensions" and d.severity == :warning and
               d.message =~ "extension runtime is disabled"
           end)
  end

  test "command inventory includes extension, prompt, and skill sources" do
    cwd = temp_cwd!("command-inventory")
    File.mkdir_p!(Path.join(cwd, ".pi/prompts"))
    File.mkdir_p!(Path.join(cwd, ".pi/skills/release-notes"))

    File.write!(Path.join(cwd, ".pi/prompts/review.md"), "Review:\n$ARGUMENTS")

    File.write!(
      Path.join(cwd, ".pi/skills/release-notes/SKILL.md"),
      """
      ---
      name: release-notes
      description: Release notes helper
      ---
      # Release Notes
      Include highlights.
      """
    )

    {:ok, %{session: session}} =
      Session.create_session(%{
        model: demo_model(),
        in_memory: true,
        cwd: cwd,
        enable_resources: true,
        enable_extensions: true,
        trusted_extensions: [TestExtension],
        extensions: [TestExtension]
      })

    commands = AgentSession.get_commands(session)

    assert Enum.any?(commands, &(&1.name == "echo" and &1.source == :extension))
    assert Enum.any?(commands, &(&1.name == "review" and &1.source == :prompt))
    assert Enum.any?(commands, &(&1.name == "skill:release-notes" and &1.source == :skill))
  end

  defp demo_model do
    %Model{
      id: "claude-sonnet-3-6",
      name: "Claude Sonnet",
      api: "anthropic",
      provider: "anthropic",
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: ["text"],
      cost: %Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 8_000,
      headers: %{},
      compat: %{}
    }
  end

  defp extract_text(%{content: content}) when is_binary(content), do: content

  defp extract_text(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(&match?(%TextContent{}, &1))
    |> Enum.map(& &1.text)
    |> Enum.join("\n")
  end

  defp temp_cwd!(suffix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "expi-session-ext-test-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end
end
