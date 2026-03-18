defmodule ExpiAi.AI.HttpClient do
  @moduledoc """
  Stub HTTP client for AI providers.
  Returns errors to simulate network conditions in test environment.
  """

  @doc """
  Makes a POST request.
  Returns error to simulate network issues.
  """
  @spec post(String.t(), String.t(), list()) :: {:ok, map()} | {:error, atom()}
  def post(_url, _body, _headers) do
    {:error, :network_error}
  end

  @doc """
  Makes a GET request.
  Returns error to simulate network issues.
  """
  @spec get(String.t(), list()) :: {:ok, map()} | {:error, atom()}
  def get(_url, _headers) do
    {:error, :network_error}
  end
end