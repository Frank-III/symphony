defmodule SymphonyElixir.Orchestration.Pipeline do
  @moduledoc """
  Executes the brainstorm → arbiter → worker → judge pipeline for a single issue.

  Called from `AgentRunner` when orchestration mode is `brainstorm_arbiter_worker_judge`.
  Runs sequentially within a single process — the Orchestrator still monitors
  one task per issue and the existing retry/failure semantics are preserved.
  """

  require Logger

  alias SymphonyElixir.{Config, Orchestration}
  alias SymphonyElixir.Orchestration.Runtime

  @type phase_entry :: %{
          phase: Orchestration.phase(),
          runtime: String.t(),
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          status: :running | :completed | :failed,
          error: term() | nil
        }

  @type pipeline_state :: %{
          issue: map(),
          workspace: Path.t(),
          current_phase: Orchestration.phase(),
          phase_history: [phase_entry()],
          opts: keyword()
        }

  @spec run(map(), Path.t(), pid() | nil, keyword()) :: :ok | {:error, term()}
  def run(issue, workspace, progress_recipient \\ nil, opts \\ []) do
    Logger.info("Pipeline starting for #{issue.identifier} workspace=#{workspace}")

    Orchestration.ensure_artifact_dirs!(workspace)

    state = %{
      issue: issue,
      workspace: workspace,
      current_phase: :brainstorm,
      phase_history: [],
      opts: opts,
      progress_recipient: progress_recipient
    }

    with {:ok, state} <- run_brainstorm(state),
         {:ok, state} <- run_arbiter(state),
         {:ok, state} <- run_worker(state),
         {:ok, state} <- run_judge(state) do
      Logger.info("Pipeline completed for #{issue.identifier} phases=#{length(state.phase_history)}")
      :ok
    else
      {:error, reason} ->
        Logger.error("Pipeline failed for #{issue.identifier}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- Phase runners ---

  defp run_brainstorm(state) do
    planner_count = Config.planner_count()
    state = enter_phase(state, :brainstorm)

    results =
      1..planner_count
      |> Task.async_stream(
        fn index ->
          prompt =
            Orchestration.phase_prompt(:brainstorm, %{
              issue: state.issue,
              planner_index: index,
              proposals_dir: Orchestration.proposals_dir(state.workspace)
            })

          Runtime.run_phase(:brainstorm, state.workspace, prompt, state.issue, state.opts)
        end,
        timeout: Keyword.get(state.opts, :phase_timeout_ms, 3_600_000),
        max_concurrency: planner_count
      )
      |> Enum.to_list()

    errors =
      results
      |> Enum.with_index(1)
      |> Enum.filter(fn
        {{:ok, {:ok, _}}, _} -> false
        _ -> true
      end)

    if length(errors) > 0 do
      Logger.warning("#{length(errors)} planners failed for #{state.issue.identifier}")
    end

    proposals = Orchestration.list_proposals(state.workspace)

    if length(proposals) >= 2 do
      state = complete_phase(state, :brainstorm)
      {:ok, state}
    else
      {:error, {:insufficient_proposals, length(proposals), 2}}
    end
  end

  defp run_arbiter(state) do
    state = enter_phase(state, :arbiter)
    proposals = Orchestration.list_proposals(state.workspace)

    prompt =
      Orchestration.phase_prompt(:arbiter, %{
        issue: state.issue,
        proposal_paths: proposals,
        plan_path: Orchestration.plan_path(state.workspace)
      })

    case Runtime.run_phase(:arbiter, state.workspace, prompt, state.issue, state.opts) do
      {:ok, _result} ->
        case Orchestration.validate_plan(Orchestration.plan_path(state.workspace)) do
          {:ok, _plan} ->
            state = complete_phase(state, :arbiter)
            {:ok, state}

          {:error, reason} ->
            {:error, {:arbiter_invalid_plan, reason}}
        end

      {:error, reason} ->
        {:error, {:arbiter_failed, reason}}
    end
  end

  defp run_worker(state) do
    state = enter_phase(state, :worker)

    prompt =
      Orchestration.phase_prompt(:worker, %{
        issue: state.issue,
        plan_path: Orchestration.plan_path(state.workspace),
        cycle: Keyword.get(state.opts, :cycle, 1),
        total_cycles: Keyword.get(state.opts, :total_cycles, 20)
      })

    case Runtime.run_phase(:worker, state.workspace, prompt, state.issue, state.opts) do
      {:ok, _result} ->
        state = complete_phase(state, :worker)
        {:ok, state}

      {:error, reason} ->
        {:error, {:worker_failed, reason}}
    end
  end

  defp run_judge(state) do
    state = enter_phase(state, :judge)

    prompt =
      Orchestration.phase_prompt(:judge, %{
        issue: state.issue,
        plan_path: Orchestration.plan_path(state.workspace),
        judge_path: Orchestration.judge_path(state.workspace)
      })

    case Runtime.run_phase(:judge, state.workspace, prompt, state.issue, state.opts) do
      {:ok, _result} ->
        case Orchestration.validate_judge(Orchestration.judge_path(state.workspace)) do
          {:ok, judge} ->
            linear_evidence = Map.get(judge, "linear_tool_usage", [])

            if length(linear_evidence) > 0 do
              state = complete_phase(state, :judge)
              {:ok, state}
            else
              Logger.warning("Judge for #{state.issue.identifier} did not record Linear tool usage")
              state = complete_phase(state, :judge)
              {:ok, state}
            end

          {:error, reason} ->
            {:error, {:judge_invalid_artifact, reason}}
        end

      {:error, reason} ->
        {:error, {:judge_failed, reason}}
    end
  end

  # --- Phase lifecycle ---

  defp enter_phase(state, phase) do
    Logger.info("Entering phase=#{phase} for #{state.issue.identifier}")
    send_progress(state, {:phase_started, phase})

    entry = %{
      phase: phase,
      runtime: Orchestration.runtime_for_phase(phase),
      started_at: DateTime.utc_now(),
      completed_at: nil,
      status: :running,
      error: nil
    }

    %{state | current_phase: phase, phase_history: state.phase_history ++ [entry]}
  end

  defp complete_phase(state, phase) do
    Logger.info("Completed phase=#{phase} for #{state.issue.identifier}")
    send_progress(state, {:phase_completed, phase})

    history =
      Enum.map(state.phase_history, fn entry ->
        if entry.phase == phase and entry.status == :running do
          %{entry | completed_at: DateTime.utc_now(), status: :completed}
        else
          entry
        end
      end)

    %{state | phase_history: history}
  end

  defp send_progress(%{progress_recipient: nil}, _msg), do: :ok

  defp send_progress(%{progress_recipient: pid, issue: issue}, msg) when is_pid(pid) do
    send(pid, {:pipeline_progress, issue.id, msg})
    :ok
  end
end
