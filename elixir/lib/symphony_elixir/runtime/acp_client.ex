defmodule SymphonyElixir.Runtime.ACPClient do
  @moduledoc """
  Generic ACP (Agent Communication Protocol) HTTP client.

  Handles session startup, turn execution, streaming events, tool calls,
  approval pauses, cancellation, teardown, and error normalization.
  Profile-driven so adding new ACP agents only requires profile data.
  """

  require Logger

  @default_turn_timeout_ms 600_000
  @default_read_timeout_ms 30_000

  @type session :: %{
          session_id: String.t(),
          endpoint: String.t(),
          auth: String.t() | nil,
          model: String.t() | nil,
          provider: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          turn_timeout_ms: pos_integer(),
          read_timeout_ms: pos_integer()
        }

  @spec create_session(String.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def create_session(endpoint, opts \\ []) do
    auth = Keyword.get(opts, :auth)
    model = Keyword.get(opts, :model)
    provider = Keyword.get(opts, :provider, "unknown")
    workspace = Keyword.get(opts, :workspace, "")
    worker_host = Keyword.get(opts, :worker_host)
    turn_timeout = Keyword.get(opts, :turn_timeout_ms) || @default_turn_timeout_ms
    read_timeout = Keyword.get(opts, :read_timeout_ms) || @default_read_timeout_ms

    body = %{
      "workspace" => workspace,
      "provider" => provider
    }

    body = if model, do: Map.put(body, "model", model), else: body
    body = if worker_host, do: Map.put(body, "worker_host", worker_host), else: body

    case post(endpoint <> "/sessions", body, auth, read_timeout) do
      {:ok, %{"session_id" => session_id}} ->
        {:ok,
         %{
           session_id: session_id,
           endpoint: endpoint,
           auth: auth,
           model: model,
           provider: provider,
           workspace: workspace,
           worker_host: worker_host,
           turn_timeout_ms: turn_timeout,
           read_timeout_ms: read_timeout
         }}

      {:ok, response} ->
        {:error, {:unexpected_session_response, response}}

      {:error, _} = error ->
        error
    end
  end

  @spec execute_turn(session(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute_turn(session, prompt, opts \\ []) do
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)

    body = %{
      "session_id" => session.session_id,
      "prompt" => prompt
    }

    case post(session.endpoint <> "/turns", body, session.auth, session.turn_timeout_ms) do
      {:ok, %{"turn_id" => turn_id, "status" => "completed"} = result} ->
        on_event.(%{type: :turn_completed, turn_id: turn_id})

        {:ok,
         %{
           turn_id: turn_id,
           session_id: session.session_id,
           result: Map.get(result, "result"),
           input_tokens: Map.get(result, "input_tokens", 0),
           output_tokens: Map.get(result, "output_tokens", 0)
         }}

      {:ok, %{"turn_id" => turn_id, "status" => "failed", "error" => error}} ->
        on_event.(%{type: :turn_failed, turn_id: turn_id, error: error})
        {:error, {:turn_failed, error}}

      {:ok, %{"status" => "approval_required"} = result} ->
        on_event.(%{type: :approval_required, detail: result})
        {:error, {:approval_required, result}}

      {:ok, response} ->
        {:error, {:unexpected_turn_response, response}}

      {:error, _} = error ->
        error
    end
  end

  @spec cancel_session(session()) :: :ok | {:error, term()}
  def cancel_session(session) do
    case post(session.endpoint <> "/sessions/#{session.session_id}/cancel", %{}, session.auth, session.read_timeout_ms) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @spec destroy_session(session()) :: :ok | {:error, term()}
  def destroy_session(session) do
    case delete(session.endpoint <> "/sessions/#{session.session_id}", session.auth, session.read_timeout_ms) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  end

  defp post(url, body, auth, timeout) do
    headers = base_headers(auth)

    case Req.post(url, json: body, headers: headers, receive_timeout: timeout) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("ACP request failed: status=#{status} body=#{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("ACP request error: #{inspect(reason)}")
        {:error, {:transport_error, reason}}
    end
  end

  defp delete(url, auth, timeout) do
    headers = base_headers(auth)

    case Req.delete(url, headers: headers, receive_timeout: timeout) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, {:transport_error, reason}}
    end
  end

  defp base_headers(nil), do: [{"content-type", "application/json"}]

  defp base_headers(auth) when is_binary(auth) do
    [{"content-type", "application/json"}, {"authorization", "Bearer #{auth}"}]
  end
end
