defmodule Expi.AI.HttpClient do
  @moduledoc """
  Production HTTP client for AI providers using HTTPoison.
  Handles connection pooling, SSL verification, and proper error handling.
  """

  @doc """
  Makes a POST request with production HTTPoison implementation.
  """
  @spec post(String.t(), String.t(), list()) :: {:ok, map()} | {:error, atom()}
  def post(url, body, headers) do
    options = [
      timeout: 30_000,
      recv_timeout: 60_000,
      ssl: [verify: :verify_peer],
      hackney: [pool: :ai_pool]
    ]

    case HTTPoison.post(url, body, headers, options) do
      {:ok, %HTTPoison.Response{status_code: status, body: response_body}} ->
        {:ok, %{status: status, body: response_body}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        map_httpoison_error(reason)
    end
  end

  @doc """
  Makes a GET request with production HTTPoison implementation.
  """
  @spec get(String.t(), list()) :: {:ok, map()} | {:error, atom()}
  def get(url, headers) do
    options = [
      timeout: 30_000,
      recv_timeout: 60_000,
      ssl: [verify: :verify_peer],
      hackney: [pool: :ai_pool]
    ]

    case HTTPoison.get(url, headers, options) do
      {:ok, %HTTPoison.Response{status_code: status, body: response_body}} ->
        {:ok, %{status: status, body: response_body}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        map_httpoison_error(reason)
    end
  end

  @doc """
  Makes a streaming POST request for Server-Sent Events.
  """
  @spec stream_post(String.t(), map() | String.t(), list()) :: {:ok, Enumerable.t()} | {:error, atom()}
  def stream_post(url, body, headers) do
    # Start the async request immediately and collect all chunks
    options = [
      # 5 minutes in milliseconds
      timeout: 300_000,
      # 5 minutes in milliseconds
      recv_timeout: 300_000,
      ssl: [verify: :verify_peer],
      hackney: [pool: :ai_stream_pool],
      stream_to: self(),
      async: :once
    ]

    encoded_body = if is_binary(body), do: body, else: Jason.encode!(body)

    case HTTPoison.post(url, encoded_body, headers, options) do
      {:ok, %HTTPoison.AsyncResponse{id: id}} ->
        # Collect all chunks immediately
        chunks = collect_all_chunks(id)
        # Convert list to stream - just return the list, it's enumerable
        {:ok, chunks}

      {:error, %HTTPoison.Error{reason: reason}} ->
        map_httpoison_error(reason)
    end
  end

  # Collect all async chunks immediately  
  defp collect_all_chunks(id) do
    collect_chunks_loop(id, [])
  end

  defp collect_chunks_loop(id, acc) do
    receive do
      %HTTPoison.AsyncStatus{id: ^id, code: status} when status >= 400 ->
        # Return error chunk and stop
        reason =
          case status do
            401 -> "authentication_error"
            403 -> "permission_error"
            429 -> "rate_limit_error"
            500 -> "api_error"
            _ -> "http_error"
          end

        error_chunk = """
        event: error
        data: {"error": {"type": "#{reason}", "message": "HTTP #{status} error"}}

        """

        Enum.reverse([error_chunk | acc])

      %HTTPoison.AsyncStatus{id: ^id, code: _status} ->
        # Good status, continue
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        collect_chunks_loop(id, acc)

      %HTTPoison.AsyncHeaders{id: ^id, headers: _headers} ->
        # Headers received, continue
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        collect_chunks_loop(id, acc)

      %HTTPoison.AsyncChunk{id: ^id, chunk: chunk} ->
        # Chunk received, continue
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        collect_chunks_loop(id, [chunk | acc])

      %HTTPoison.AsyncEnd{id: ^id} ->
        # End of stream, return all chunks
        Enum.reverse(acc)
    after
      30_000 ->
        # Timeout, return what we have
        Enum.reverse(acc)
    end
  end

  # Private functions

  defp map_httpoison_error(:timeout), do: {:error, :timeout}
  defp map_httpoison_error(:econnrefused), do: {:error, :connection_refused}
  defp map_httpoison_error(:nxdomain), do: {:error, :dns_error}
  defp map_httpoison_error(:closed), do: {:error, :connection_closed}
  defp map_httpoison_error(:ssl_closed), do: {:error, :ssl_error}
  defp map_httpoison_error(_), do: {:error, :network_error}
end
