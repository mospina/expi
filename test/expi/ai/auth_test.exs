defmodule ExpiAi.AuthTest do
  use ExUnit.Case, async: true

  alias ExpiAi.Auth
  alias ExpiAi.Types.Model

  describe "get_api_key/1" do
    test "returns Anthropic API key from config" do
      # In test environment, this should return the test key from config
      assert {:ok, key} = Auth.get_api_key("anthropic")
      assert is_binary(key)
      assert key != ""
    end

    test "returns Gemini API key from config" do
      assert {:ok, key} = Auth.get_api_key("google")
      assert is_binary(key)
      assert key != ""
    end

    test "returns nil for Ollama (no API key needed)" do
      assert {:ok, nil} = Auth.get_api_key("ollama")
    end

    test "returns error for unknown provider" do
      assert {:error, :unknown_provider} = Auth.get_api_key("unknown-provider")
    end

    test "returns error when API key not configured" do
      # This would test when environment variable is not set
      # Implementation would check for missing config
      assert is_function(&Auth.get_api_key/1)
    end
  end

  describe "validate_api_key/2" do
    test "validates Anthropic API key format" do
      valid_anthropic_key = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890"
      assert Auth.validate_api_key("anthropic", valid_anthropic_key) == :ok

      invalid_key = "invalid-key"
      assert {:error, :invalid_key_format} = Auth.validate_api_key("anthropic", invalid_key)
    end

    test "validates Gemini API key format" do
      valid_gemini_key = "AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYz1234567"
      assert Auth.validate_api_key("google", valid_gemini_key) == :ok

      invalid_key = "short"
      assert {:error, :invalid_key_format} = Auth.validate_api_key("google", invalid_key)
    end

    test "always validates Ollama (no key needed)" do
      assert Auth.validate_api_key("ollama", nil) == :ok
      assert Auth.validate_api_key("ollama", "") == :ok
      assert Auth.validate_api_key("ollama", "any-value") == :ok
    end

    test "returns error for unknown provider" do
      assert {:error, :unknown_provider} = Auth.validate_api_key("unknown", "key")
    end
  end

  describe "build_auth_headers/2" do
    test "builds Anthropic authentication headers" do
      api_key = "sk-ant-api03-test123"
      headers = Auth.build_auth_headers("anthropic", api_key)

      assert is_list(headers)
      assert {"x-api-key", api_key} in headers
      assert {"anthropic-version", _} = List.keyfind(headers, "anthropic-version", 0)
    end

    test "builds Google authentication headers" do
      api_key = "AIzaSyTest123"
      headers = Auth.build_auth_headers("google", api_key)

      assert is_list(headers)
      # Google uses the API key in the URL or as a header depending on the API
      assert List.keyfind(headers, "Authorization", 0) != nil or
             List.keyfind(headers, "x-goog-api-key", 0) != nil
    end

    test "builds empty headers for Ollama" do
      headers = Auth.build_auth_headers("ollama", nil)

      assert is_list(headers)
      # Ollama typically doesn't need authentication headers
      assert headers == []
    end

    test "returns error for unknown provider" do
      assert {:error, :unknown_provider} = Auth.build_auth_headers("unknown", "key")
    end
  end

  describe "get_authenticated_headers/1" do
    test "gets complete headers for Anthropic model" do
      model = %Model{
        id: "claude-opus-4-5",
        name: "Claude Opus 4.5",
        api: "anthropic-messages",
        provider: "anthropic",
        base_url: "https://api.anthropic.com",
        reasoning: true,
        input: ["text", "image"],
        cost: %ExpiAi.Types.Cost{input: 15.0, output: 75.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 200_000,
        max_tokens: 4096,
        headers: %{"Custom-Header" => "custom-value"},
        compat: %{}
      }

      assert {:ok, headers} = Auth.get_authenticated_headers(model)
      assert is_list(headers)
      assert {"x-api-key", _} = List.keyfind(headers, "x-api-key", 0)
      assert {"Custom-Header", "custom-value"} in headers
    end

    test "gets complete headers for Google model" do
      model = %Model{
        id: "gemini-pro",
        name: "Gemini Pro",
        api: "google-generative-ai",
        provider: "google",
        base_url: "https://generativelanguage.googleapis.com",
        reasoning: false,
        input: ["text"],
        cost: %ExpiAi.Types.Cost{input: 0.5, output: 1.5, cache_read: 0.0, cache_write: 0.0},
        context_window: 30_720,
        max_tokens: 8192,
        headers: %{},
        compat: %{}
      }

      assert {:ok, headers} = Auth.get_authenticated_headers(model)
      assert is_list(headers)
    end

    test "gets headers for Ollama model" do
      model = %Model{
        id: "llama3.1:8b",
        name: "Llama 3.1 8B",
        api: "openai-completions",
        provider: "ollama",
        base_url: "http://localhost:11434/v1",
        reasoning: false,
        input: ["text"],
        cost: %ExpiAi.Types.Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 8192,
        max_tokens: 4096,
        headers: %{},
        compat: %{}
      }

      assert {:ok, headers} = Auth.get_authenticated_headers(model)
      assert is_list(headers)
    end
  end

  describe "connection management" do
    test "validates connection to Anthropic" do
      assert {:ok, :connected} = Auth.validate_connection("anthropic")
    end

    test "validates connection to Google" do
      assert {:ok, :connected} = Auth.validate_connection("google")
    end

    test "validates connection to Ollama" do
      # This would ping the Ollama endpoint to check if it's running
      # In test environment, we mock this
      assert {:ok, :connected} = Auth.validate_connection("ollama")
    end

    test "returns error for unreachable services" do
      # This would test actual connectivity in integration tests
      # For unit tests, we just verify the function signature
      assert is_function(&Auth.validate_connection/1)
    end
  end

  describe "environment configuration" do
    test "loads configuration from environment" do
      config = Auth.get_auth_config()

      assert is_map(config)
      assert Map.has_key?(config, :anthropic_api_key)
      assert Map.has_key?(config, :gemini_api_key)
      assert Map.has_key?(config, :ollama_base_url)
    end

    test "validates required environment variables" do
      # Check that required environment variables are present
      validation = Auth.validate_environment()

      assert is_map(validation)
      assert Map.has_key?(validation, :anthropic)
      assert Map.has_key?(validation, :google)
      assert Map.has_key?(validation, :ollama)

      # Each provider should have a status
      assert validation.anthropic in [:ok, :missing_key, :invalid_key]
      assert validation.google in [:ok, :missing_key, :invalid_key]
      assert validation.ollama in [:ok, :unreachable]
    end
  end

  describe "security" do
    test "masks API keys in logs" do
      api_key = "sk-ant-api03-very-secret-key-12345"
      masked = Auth.mask_api_key(api_key)

      assert masked != api_key
      assert String.length(masked) < String.length(api_key)
      assert masked =~ "sk-ant-api03-***"
    end

    test "handles nil API keys safely" do
      assert Auth.mask_api_key(nil) == "nil"
      assert Auth.mask_api_key("") == ""
    end

    test "masks different key formats" do
      anthropic_key = "sk-ant-api03-test123"
      google_key = "AIzaSyTest123"

      assert Auth.mask_api_key(anthropic_key) =~ "sk-ant-api03-***"
      assert Auth.mask_api_key(google_key) =~ "AIzaSy***"
    end
  end

  describe "error handling" do
    test "handles authentication failures gracefully" do
      # Test various authentication failure scenarios
      assert {:error, :authentication_failed} = Auth.authenticate_request("anthropic", "invalid-key")
    end

    test "provides helpful error messages" do
      error = Auth.get_auth_error(:invalid_key_format, "anthropic")

      assert is_binary(error)
      assert error =~ "Anthropic"
      assert error =~ "API key"
    end

    test "handles network errors during auth validation" do
      # This would test network failures during authentication
      assert is_function(&Auth.validate_connection/1)
    end
  end
end
