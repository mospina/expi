defmodule Expi.Session.ResourceLoaderTest do
  @moduledoc """
  Test for ResourceLoader functionality.

  This test ensures that the expand_skill_command function generates proper XML
  and handles various edge cases correctly.
  """
  use ExUnit.Case

  alias Expi.Session.ResourceLoader

  describe "expand_skill_command/2" do
    test "generates proper skill block XML" do
      # Create a temporary directory and skill file
      temp_dir = System.tmp_dir!()
      skill_dir = Path.join(temp_dir, "test_skill_#{:rand.uniform(10000)}")
      File.mkdir_p!(skill_dir)

      skill_file = Path.join(skill_dir, "SKILL.md")

      skill_content = """
      ---
      name: test-skill
      description: A test skill for validation
      ---

      This is a test skill body.
      """

      File.write!(skill_file, skill_content)

      # Create a ResourceLoader with the skill
      loader =
        ResourceLoader.new(%{
          include_defaults: false,
          skill_paths: [skill_dir]
        })

      # Test that expand_skill_command produces expected XML structure
      result = ResourceLoader.expand_skill_command("/skill:test-skill", loader)

      # Verify the XML structure is correct
      assert result =~ ~r/<skill name="test-skill" location=".*SKILL\.md">/
      assert result =~ "References are relative to"
      assert result =~ "This is a test skill body."
      assert result =~ "</skill>"

      # Verify it contains the skill name and file path properly escaped
      assert result =~ "test-skill"
      assert result =~ "SKILL.md"

      # Clean up
      File.rm_rf!(skill_dir)
    end

    test "handles skill names and paths with special characters" do
      # Create a temporary directory and skill file with special characters
      temp_dir = System.tmp_dir!()
      skill_dir = Path.join(temp_dir, "test_skill_#{:rand.uniform(10000)}")
      File.mkdir_p!(skill_dir)

      skill_file = Path.join(skill_dir, "SKILL.md")

      skill_content = """
      ---
      name: test-skill-with-quotes
      description: A skill with "quotes" and 'apostrophes'
      ---

      This skill has "double quotes" and 'single quotes' in its content.
      """

      File.write!(skill_file, skill_content)

      # Create a ResourceLoader with the skill
      loader =
        ResourceLoader.new(%{
          include_defaults: false,
          skill_paths: [skill_dir]
        })

      # Test that expand_skill_command handles special characters correctly
      result = ResourceLoader.expand_skill_command("/skill:test-skill-with-quotes", loader)

      # Verify the XML structure is still valid despite special characters
      assert result =~ ~r/<skill name="test-skill-with-quotes" location=".*SKILL\.md">/
      assert result =~ ~s(This skill has "double quotes")
      assert result =~ ~s(and 'single quotes')
      assert result =~ "</skill>"

      # Clean up
      File.rm_rf!(skill_dir)
    end

    test "uses sigils for XML generation to avoid string literal issues" do
      # This test validates that the source code uses proper string handling
      # techniques for XML generation

      # Read the source file
      source_file = Path.join(File.cwd!(), "lib/expi/session/resource_loader.ex")
      {:ok, source_content} = File.read(source_file)

      # Check that the expand_skill_command function uses proper string handling
      lines = String.split(source_content, "\n")

      # Find the expand_skill_command function
      expand_skill_start =
        Enum.find_index(lines, &String.contains?(&1, "def expand_skill_command"))

      refute is_nil(expand_skill_start), "expand_skill_command function should exist"

      # Look at the function body (reasonable range)
      function_lines = Enum.slice(lines, expand_skill_start, 20)
      function_body = Enum.join(function_lines, "\n")

      # Verify we're using sigils instead of strings with multiple quotes
      # The problematic pattern would be: "string with \"multiple\" \"quotes\""
      problematic_pattern = ~r/"[^"]*\\"[^"]*\\"[^"]*"/

      refute Regex.match?(problematic_pattern, function_body),
             "Function should not contain string literals with multiple escaped quotes"

      # Verify we are using sigils for the XML generation
      assert String.contains?(function_body, "~s("),
             "Function should use sigils (~s) for XML generation"
    end
  end
end
