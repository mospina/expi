#!/usr/bin/env elixir

# Simple Session-based CLI coding assistant demo
#
# Usage:
#   cd expi
#   elixir demos/session_cli_coding_assistant_demo.exs
#
# Optional env vars:
#   DEMO_PROVIDER=anthropic
#   DEMO_MODEL_ID=claude-sonnet-3-6

Mix.install([
  {:expi, path: "."},
  {:owl, "~> 0.13"}
])

defmodule SessionCliCodingAssistantDemo do
  alias Expi.Session
  alias Expi.Session.AgentSession

  @system_prompt """
  You are Expi CLI, a concise coding assistant.
  Priorities:
  - Be accurate, practical, and brief.
  - When using tools, prefer minimal-impact actions first.
  - Explain assumptions and risks before destructive changes.
  - For code tasks, provide clear next steps.

  Execution policy:
  - If the user asks to create or modify a file, perform the file operation with tools in the same turn.
  - Do not stop at intent-only statements like "I'll do X".
  - After tool use, provide a short completion summary including target file path.
  """

  def run do
    provider = System.get_env("DEMO_PROVIDER", "anthropic")
    model_id = System.get_env("DEMO_MODEL_ID", "claude-sonnet-3-6")

    print_header(provider, model_id)

    with {:ok, %{session: session}} <-
           Session.create_session(%{
             provider: provider,
             model_id: model_id,
             in_memory: true,
             enable_resources: true,
             system_prompt: @system_prompt
           }) do
      Owl.IO.puts(info("Session initialized. Ask anything about your codebase."))
      loop(session)
    else
      {:error, reason} ->
        Owl.IO.puts(error("Session init failed: #{inspect(reason)}"))
    end
  end

  defp loop(session) do
    input = Owl.IO.input([prompt("you"), " "])

    cond do
      is_nil(input) ->
        Owl.IO.puts(["\n", info("Goodbye 👋")])

      true ->
        case String.trim(input) do
          "" ->
            loop(session)

          "/quit" ->
            Owl.IO.puts(info("Goodbye 👋"))

          "/help" ->
            Owl.IO.puts(info("Commands: /help, /quit"))
            loop(session)

          prompt_text ->
            Owl.IO.puts(info("assistant is thinking..."))

            case AgentSession.prompt(session, prompt_text, %{run_conversation: true}) do
              {:ok, updated} ->
                print_last_assistant(updated)
                Owl.IO.puts("")
                loop(updated)

              {:error, reason} ->
                Owl.IO.puts(error("Prompt failed: #{inspect(reason)}"))
                loop(session)
            end
        end
    end
  end

  defp print_last_assistant(session) do
    text =
      session
      |> AgentSession.messages()
      |> Enum.reverse()
      |> Enum.find_value(fn msg ->
        if Map.get(msg, :role) in [:assistant, "assistant"], do: extract_text(msg), else: nil
      end)

    Owl.IO.puts([prompt("assistant"), " ", text || "(no assistant text)"])
  end

  defp print_header(provider, model_id) do
    Owl.IO.puts(Owl.Data.tag(" Expi CLI Coding Assistant Demo ", :cyan))
    Owl.IO.puts([label("Model:"), " #{provider}/#{model_id}"])
    Owl.IO.puts([label("Mode:"), " Session (ephemeral) | Tools: default"])
    Owl.IO.puts([label("System Prompt:"), " enabled"])
    Owl.IO.puts(info("Type your prompt and press Enter. /help for commands, /quit to exit."))
    Owl.IO.puts(String.duplicate("─", 72))
  end

  defp extract_text(message) do
    content = Map.get(message, :content)

    cond do
      is_binary(content) ->
        content

      is_list(content) ->
        content
        |> Enum.map(fn part ->
          cond do
            is_map(part) and is_binary(Map.get(part, :text)) -> Map.get(part, :text)
            is_map(part) and is_binary(Map.get(part, "text")) -> Map.get(part, "text")
            true -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      true ->
        ""
    end
  end

  defp label(text), do: Owl.Data.tag(text, :yellow)
  defp info(text), do: Owl.Data.tag(text, :light_black)
  defp error(text), do: Owl.Data.tag(text, :red)
  defp prompt(name), do: Owl.Data.tag("#{name}>", :green)
end

SessionCliCodingAssistantDemo.run()
