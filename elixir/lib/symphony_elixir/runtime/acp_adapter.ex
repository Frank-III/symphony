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
  alias SymphonyElixir.Runtime.ACPStdioClient

  @impl true
  def start_session(%RuntimeProfile{} = profile, workspace, opts \\ []) do
    case transport_for(profile) do
      {:ok, "http"} ->
        start_http_session(profile, workspace, opts)

      {:ok, "stdio"} ->
        start_stdio_session(profile, workspace, opts)

      {:error, _} = error ->
        error
    end
  end

  defp start_http_session(%RuntimeProfile{} = profile, workspace, opts) do
    endpoint = profile.endpoint

    if is_nil(endpoint) or endpoint == "" do
      {:error, {:acp_config_error, profile.name, :missing_endpoint}}
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

  defp start_stdio_session(%RuntimeProfile{} = profile, workspace, opts) do
    case ACPStdioClient.create_session(profile, workspace, opts) do
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

  @impl true
  def run_turn(session, prompt, _issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)

    on_event = fn event ->
      on_message.(%{type: event.type, data: event})
    end

    case execute_turn(session.acp_session, prompt, on_event: on_event) do
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
    stop_acp_session(session.acp_session)
    :ok
  end

  @impl true
  def runtime_metadata(session) do
    profile = session.profile

    %{
      profile_name: profile.name,
      provider: profile.provider,
      adapter: profile.adapter,
      transport: Map.get(session.acp_session, :transport, transport_for!(profile)),
      display_name: profile.display_name,
      session_id: session.acp_session.session_id,
      turn_count: session.turn_count,
      input_tokens: session.input_tokens,
      output_tokens: session.output_tokens,
      total_tokens: session.total_tokens,
      last_event: session.last_event,
      health: :healthy
    }
  end

  defp execute_turn(%{transport: "stdio"} = acp_session, prompt, opts) do
    ACPStdioClient.execute_turn(acp_session, prompt, opts)
  end

  defp execute_turn(acp_session, prompt, opts), do: ACPClient.execute_turn(acp_session, prompt, opts)

  defp stop_acp_session(%{transport: "stdio"} = acp_session), do: ACPStdioClient.stop_session(acp_session)
  defp stop_acp_session(acp_session), do: ACPClient.destroy_session(acp_session)

  defp transport_for(%RuntimeProfile{transport: transport}) when transport in ["http", "stdio"], do: {:ok, transport}
  defp transport_for(%RuntimeProfile{name: name, transport: transport}) when is_binary(transport), do: {:error, {:acp_config_error, name, {:invalid_transport, transport}}}
  defp transport_for(%RuntimeProfile{endpoint: endpoint}) when is_binary(endpoint) and endpoint != "", do: {:ok, "http"}
  defp transport_for(%RuntimeProfile{command: command}) when is_binary(command) and command != "", do: {:ok, "stdio"}
  defp transport_for(%RuntimeProfile{name: name}), do: {:error, {:acp_config_error, name, :missing_transport_config}}

  defp transport_for!(profile) do
    case transport_for(profile) do
      {:ok, transport} -> transport
      {:error, _} -> nil
    end
  end
end
