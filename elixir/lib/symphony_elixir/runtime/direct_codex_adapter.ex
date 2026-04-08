defmodule SymphonyElixir.Runtime.DirectCodexAdapter do
  @moduledoc """
  Runtime adapter that wraps the existing `Codex.AppServer` transport.

  Preserves the current direct stdio-based Codex flow while conforming
  to the `Runtime.Adapter` behaviour.
  """

  @behaviour SymphonyElixir.Runtime.Adapter

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config.Schema.RuntimeProfile

  @impl true
  def start_session(%RuntimeProfile{} = profile, workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    session_opts =
      [worker_host: worker_host]
      |> maybe_put(:command, profile.command)
      |> maybe_put(:approval_policy, profile.approval_policy)
      |> maybe_put(:thread_sandbox, profile.thread_sandbox)
      |> maybe_put(:turn_sandbox_policy, profile.turn_sandbox_policy)
      |> maybe_put(:turn_timeout_ms, profile.turn_timeout_ms)
      |> maybe_put(:read_timeout_ms, profile.read_timeout_ms)
      |> maybe_put(:stall_timeout_ms, profile.stall_timeout_ms)

    case AppServer.start_session(workspace, session_opts) do
      {:ok, app_session} ->
        {:ok,
         %{
           __adapter__: __MODULE__,
           profile: profile,
           app_session: app_session,
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
  def run_turn(session, prompt, issue, opts \\ []) do
    case AppServer.run_turn(session.app_session, prompt, issue, opts) do
      {:ok, turn_result} ->
        updated_session = %{
          session
          | turn_count: session.turn_count + 1,
            last_event: :turn_completed
        }

        {:ok, Map.put(turn_result, :session, updated_session)}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def stop_session(session) do
    AppServer.stop_session(session.app_session)
  end

  @impl true
  def runtime_metadata(session) do
    profile = session.profile

    %{
      profile_name: profile.name,
      provider: profile.provider,
      adapter: profile.adapter,
      session_id: get_in(session, [:app_session, :thread_id]),
      turn_count: session.turn_count,
      input_tokens: session.input_tokens,
      output_tokens: session.output_tokens,
      total_tokens: session.total_tokens,
      last_event: session.last_event,
      health: :healthy
    }
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
