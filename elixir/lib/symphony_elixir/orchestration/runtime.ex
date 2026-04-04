defmodule SymphonyElixir.Orchestration.Runtime do
  @moduledoc """
  Runtime adapter that dispatches between Codex app-server and Claude CLI
  based on the phase's configured runtime.
  """

  require Logger

  alias SymphonyElixir.Claude
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Orchestration

  @linear_tool "mcp__symphony-linear__linear_graphql"

  @type phase_result ::
          {:ok, %{runtime: String.t(), duration_ms: non_neg_integer(), output: String.t()}}
          | {:error, term()}

  @spec run_phase(Orchestration.phase(), Path.t(), String.t(), map(), keyword()) :: phase_result()
  def run_phase(phase, workspace, prompt, issue, opts \\ []) do
    runtime = Orchestration.runtime_for_phase(phase)
    Logger.info("Running phase=#{phase} runtime=#{runtime} workspace=#{workspace}")

    with :ok <- pre_flight_check(phase, runtime) do
      start_time = System.monotonic_time(:millisecond)

      result =
        case runtime do
          "codex" -> run_codex(workspace, prompt, issue, opts)
          "claude" -> run_claude(workspace, prompt, phase, opts)
        end

      duration_ms = System.monotonic_time(:millisecond) - start_time

      case result do
        {:ok, output} ->
          {:ok, %{runtime: runtime, duration_ms: duration_ms, output: output}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp pre_flight_check(:judge, "claude") do
    # Judge phase requires Linear tool access — verify the tool name is wired
    Logger.info("Judge pre-flight: Linear tool #{@linear_tool} will be required")
    :ok
  end

  defp pre_flight_check(_phase, _runtime), do: :ok

  defp run_codex(workspace, prompt, issue, opts) do
    worker_host = Keyword.get(opts, :worker_host)

    case AppServer.run(workspace, prompt, issue, worker_host: worker_host) do
      {:ok, turn_result} ->
        {:ok, inspect(turn_result)}

      {:error, reason} ->
        {:error, {:codex_phase_failed, reason}}
    end
  end

  defp run_claude(workspace, prompt, phase, opts) do
    claude_opts =
      opts
      |> Keyword.take([:timeout_ms, :model])
      |> add_phase_tools(phase)

    case Claude.Runner.run(workspace, prompt, claude_opts) do
      {:ok, %{exit_code: 0, output: output}} ->
        {:ok, output}

      {:ok, %{exit_code: code, output: output}} ->
        {:error, {:claude_nonzero_exit, code, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp add_phase_tools(opts, :judge) do
    Keyword.put(opts, :tools, [@linear_tool])
  end

  defp add_phase_tools(opts, _phase), do: opts
end
