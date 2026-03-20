defmodule ExpiAi.AI.HttpClient do
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
  Makes a streaming GET request for Server-Sent Events.
  """
  @spec get_stream(String.t(), list()) :: {:ok, Enumerable.t()} | {:error, atom()}
  def get_stream(url, headers) do
    options = [
      timeout: :infinity,
      recv_timeout: :infinity,
      ssl: [verify: :verify_peer],
      hackney: [pool: :ai_stream_pool],
      stream_to: self(),
      async: :once
    ]

    case HTTPoison.get(url, headers, options) do
      {:ok, %HTTPoison.AsyncResponse{id: id}} ->
        stream = create_sse_stream(id)
        {:ok, stream}
      
      {:error, %HTTPoison.Error{reason: reason}} ->
        map_httpoison_error(reason)
    end
  end

  # Private functions

  defp map_httpoison_error(:timeout), do: {:error, :timeout}
  defp map_httpoison_error(:econnrefused), do: {:error, :connection_refused}
  defp map_httpoison_error(:nxdomain), do: {:error, :dns_error}
  defp map_httpoison_error(:closed), do: {:error, :connection_closed}
  defp map_httpoison_error(:ssl_closed), do: {:error, :ssl_error}
  defp map_httpoison_error(_), do: {:error, :network_error}

  defp create_sse_stream(request_id) do
    Stream.resource(
      fn -> request_id end,
      fn id ->
        receive do
          %HTTPoison.AsyncChunk{id: ^id, chunk: chunk} ->
            HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
            {[chunk], id}
          
          %HTTPoison.AsyncEnd{id: ^id} ->
            {:halt, id}
          
          %HTTPoison.AsyncStatus{id: ^id, code: status} when status >= 400 ->
            {:halt, id}
        after
          30_000 ->
            {:halt, id}
        end
      end,
      fn _id -> :ok end
    )
  end
end