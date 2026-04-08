defmodule SymphonyElixir.Runtime.ACPAdapter do
  @moduledoc """
  Runtime adapter for ACP-backed agents.

  Fully profile-driven: Claude, Codex, Pi, and OpenCode all use this
  adapter with different profile data. Adding future ACP agents only
  requires a new profile config entry.
  """

  @behaviour SymphonyElixir.Runtime.Adapter

  alias SymphonyElixir.Config.Schema.RuntimeProfile
  alias SymphonyElixir.Runtime.ACPClient

  @impl true
  def start_session(%RuntimeProfile{} = profile, workspace, opts \\ []) do
    endpoint = profile.endpoint

    if is_nil(endpoint) or endpoint == "" do
      {:error, {:missing_endpoint, profile.name}}
    else
      client_opts =
        [
          auth: profile.auth,
          model: profile.model,
          provider: profile.provider,
          workspace: workspace,
          turn_timeout_ms: profile.turn_timeout_ms,
          read_timeout_ms: profile.read_timeout_ms
        ] ++ Keyword.take(opts, [:worker_host])

      case ACPClient.create_session(endpoint, client_opts) do
        {:ok, acp_session} ->
          {:ok,
           %{
             __adapter__: __MODULE__,
             profile: profile,
             acp_session: acp_session,
             turn_count: 0,
             input_tokens: 0,
             output_tokens: 0,
             total_tokens: 0,
             last_event: nil
           }}

        {:error, _} = error ->
          error
      end
    end
  end

  @impl true
  def run_turn(session, prompt, _issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)

    on_event = fn event ->
      on_message.(%{type: event.type, data: event})
    end

    case ACPClient.execute_turn(session.acp_session, prompt, on_event: on_event) do
      {:ok, turn_result} ->
        updated_session = %{
          session
          | turn_count: session.turn_count + 1,
            input_tokens: session.input_tokens + Map.get(turn_result, :input_tokens, 0),
            output_tokens: session.output_tokens + Map.get(turn_result, :output_tokens, 0),
            total_tokens:
              session.total_tokens +
                Map.get(turn_result, :input_tokens, 0) +
                Map.get(turn_result, :output_tokens, 0),
            last_event: :turn_completed
        }

        {:ok, Map.put(turn_result, :session, updated_session)}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def stop_session(session) do
    ACPClient.destroy_session(session.acp_session)
    :ok
  end

  @impl true
  def runtime_metadata(session) do
    profile = session.profile

    %{
      profile_name: profile.name,
      provider: profile.provider,
      adapter: profile.adapter,
      session_id: session.acp_session.session_id,
      turn_count: session.turn_count,
      input_tokens: session.input_tokens,
      output_tokens: session.output_tokens,
      total_tokens: session.total_tokens,
      last_event: session.last_event,
      health: :healthy
    }
  end
end
