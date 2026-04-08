defmodule SymphonyElixir.Runtime.ACPClient do
  @moduledoc """
  Generic ACP (Agent Communication Protocol) HTTP client.

  Handles session startup, turn execution, streaming events, tool calls,
  approval pauses, cancellation, teardown, and error normalization.
  Profile-driven so adding new ACP agents only requires profile data.
  """

  require Logger

  @type session :: %{
          session_id: String.t(),
          endpoint: String.t(),
          auth: String.t() | nil,
          model: String.t() | nil,
          provider: String.t(),
          workspace: Path.t()
        }

  @spec create_session(String.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def create_session(endpoint, opts \\ []) do
    auth = Keyword.get(opts, :auth)
    model = Keyword.get(opts, :model)
    provider = Keyword.get(opts, :provider, "unknown")
    workspace = Keyword.get(opts, :workspace, "")

    body = %{
      "workspace" => workspace,
      "provider" => provider
    }

    body = if model, do: Map.put(body, "model", model), else: body

    case post(endpoint <> "/sessions", body, auth) do
      {:ok, %{"session_id" => session_id}} ->
        {:ok,
         %{
           session_id: session_id,
           endpoint: endpoint,
           auth: auth,
           model: model,
           provider: provider,
           workspace: workspace
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

    case post(session.endpoint <> "/turns", body, session.auth) do
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
    case post(session.endpoint <> "/sessions/#{session.session_id}/cancel", %{}, session.auth) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @spec destroy_session(session()) :: :ok | {:error, term()}
  def destroy_session(session) do
    case delete(session.endpoint <> "/sessions/#{session.session_id}", session.auth) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  end

  defp post(url, body, auth) do
    headers = base_headers(auth)

    case Req.post(url, json: body, headers: headers, receive_timeout: 600_000) do
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

  defp delete(url, auth) do
    headers = base_headers(auth)

    case Req.delete(url, headers: headers, receive_timeout: 30_000) do
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
