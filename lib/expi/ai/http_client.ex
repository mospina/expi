defmodule Expi.HttpClient do
  @moduledoc """
  HTTP client wrapper with connection pooling and JSON handling.

  Provides a simplified interface for HTTP requests with automatic
  JSON encoding/decoding and error handling.
  """

  alias Expi.Config
  alias Expi.Types.Model

  @doc """
  Performs a POST request with JSON body.
  """
  @spec post(String.t(), map(), list(), list()) ::
          {:ok, HTTPoison.Response.t()} | {:error, atom()}
  def post(url, body, headers \\ [], options \\ []) do
    json_body = Jason.encode!(body)
    full_headers = [{"Content-Type", "application/json"} | headers]
    full_options = Keyword.merge(default_options(), options)

    case HTTPoison.post(url, json_body, full_headers, full_options) do
      {:ok, %HTTPoison.Response{status_code: status} = response}
      when status >= 200 and status < 300 ->
        {:ok, response}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 400 ->
        {:error, categorize_http_error(status)}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Performs a GET request.
  """
  @spec get(String.t(), list(), list()) :: {:ok, HTTPoison.Response.t()} | {:error, atom()}
  def get(url, headers \\ [], options \\ []) do
    full_headers = default_headers() ++ headers
    full_options = Keyword.merge(default_options(), options)

    case HTTPoison.get(url, full_headers, full_options) do
      {:ok, %HTTPoison.Response{status_code: status} = response}
      when status >= 200 and status < 300 ->
        {:ok, response}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 400 ->
        {:error, categorize_http_error(status)}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Performs a streaming POST request.
  """
  @spec stream_post(String.t(), map(), list(), list()) :: {:ok, reference()} | {:error, atom()}
  def stream_post(url, body, headers \\ [], options \\ []) do
    json_body = Jason.encode!(body)
    full_headers = [{"Content-Type", "application/json"} | headers]
    full_options = Keyword.merge(default_options(), options)

    case HTTPoison.post(url, json_body, full_headers, full_options) do
      {:ok, %HTTPoison.AsyncResponse{id: ref}} ->
        {:ok, ref}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the current HTTP client configuration.
  """
  @spec get_config() :: map()
  def get_config do
    %{
      timeout: Config.http_timeout(),
      recv_timeout: Config.http_recv_timeout(),
      pool_size: Config.connection_pool_size()
    }
  end

  @doc """
  Returns default HTTP headers.
  """
  @spec default_headers() :: list()
  def default_headers do
    [
      {"Content-Type", "application/json"},
      {"User-Agent", "Expi/0.1.0"}
    ]
  end

  @doc """
  Builds request configuration from model and custom options.
  """
  @spec build_request_config(Model.t(), map(), list()) :: {String.t(), list(), list()}
  def build_request_config(%Model{} = model, _body, custom_headers \\ []) do
    url = model.base_url
    headers = merge_headers(model.headers, custom_headers)
    options = default_options()

    {url, headers, options}
  end

  @doc """
  Parses JSON response body.
  """
  @spec parse_json_response(String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def parse_json_response(nil), do: {:error, :empty_response}
  def parse_json_response(""), do: {:error, :empty_response}

  def parse_json_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  @doc """
  Categorizes HTTP error status codes.
  """
  @spec categorize_http_error(integer()) :: atom()
  def categorize_http_error(400), do: :bad_request
  def categorize_http_error(401), do: :unauthorized
  def categorize_http_error(403), do: :forbidden
  def categorize_http_error(404), do: :not_found
  def categorize_http_error(429), do: :rate_limited
  def categorize_http_error(500), do: :server_error
  def categorize_http_error(503), do: :service_unavailable
  def categorize_http_error(_), do: :unknown_http_error

  @doc """
  Formats error messages from HTTP responses.
  """
  @spec format_error_message(HTTPoison.Response.t()) :: String.t()
  def format_error_message(%HTTPoison.Response{status_code: status, body: body}) do
    case parse_json_response(body) do
      {:ok, %{"error" => %{"message" => message}}} ->
        "HTTP #{status}: #{message}"

      {:ok, %{"error" => error}} when is_binary(error) ->
        "HTTP #{status}: #{error}"

      _ ->
        "HTTP #{status}: #{categorize_http_error(status)}"
    end
  end

  # Private helper functions

  defp default_options do
    [
      timeout: Config.http_timeout(),
      recv_timeout: Config.http_recv_timeout(),
      hackney: [pool: :expi_pool]
    ]
  end

  defp merge_headers(model_headers, custom_headers) when is_map(model_headers) do
    model_header_list = Map.to_list(model_headers)
    default_headers() ++ model_header_list ++ custom_headers
  end

  defp merge_headers(_, custom_headers) do
    default_headers() ++ custom_headers
  end
end
