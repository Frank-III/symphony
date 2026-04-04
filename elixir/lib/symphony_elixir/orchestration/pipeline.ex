defmodule SymphonyElixir.Orchestration.Pipeline do
  @moduledoc """
  Executes the brainstorm → arbiter → worker → judge pipeline for a single issue.

  Called from `AgentRunner` when orchestration mode is `brainstorm_arbiter_worker_judge`.
  Runs sequentially within a single process — the Orchestrator still monitors
  one task per issue and the existing retry/failure semantics are preserved.

  Supports multi-cycle execution: when the judge returns `replan`, the pipeline
  advances to the next cycle (up to `max_cycles`) and reruns from brainstorm.
  Valid artifacts from prior phases are reused when resuming.
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
          cycle: pos_integer(),
          max_cycles: pos_integer(),
          current_phase: Orchestration.phase(),
          phase_history: [phase_entry()],
          judge_decision: String.t() | nil,
          opts: keyword()
        }

  @spec run(map(), Path.t(), pid() | nil, keyword()) :: :ok | {:error, term()}
  def run(issue, workspace, progress_recipient \\ nil, opts \\ []) do
    cycle = Keyword.get(opts, :cycle, Config.orchestration_cycle())
    max_cycles = Keyword.get(opts, :max_cycles, Config.orchestration_max_cycles())

    Logger.info("Pipeline starting for #{issue.identifier} workspace=#{workspace} cycle=#{cycle}/#{max_cycles}")

    Orchestration.ensure_artifact_dirs!(workspace)

    state = %{
      issue: issue,
      workspace: workspace,
      cycle: cycle,
      max_cycles: max_cycles,
      current_phase: :brainstorm,
      phase_history: [],
      judge_decision: nil,
      opts: opts,
      progress_recipient: progress_recipient
    }

    run_cycle(state)
  end

  # --- Multi-cycle loop ---

  defp run_cycle(%{cycle: cycle, max_cycles: max_cycles} = state) when cycle > max_cycles do
    Logger.error("Pipeline exceeded max_cycles=#{max_cycles} for #{state.issue.identifier}")
    {:error, {:max_cycles_exceeded, max_cycles}}
  end

  defp run_cycle(state) do
    Logger.info("Pipeline cycle=#{state.cycle}/#{state.max_cycles} for #{state.issue.identifier}")

    with {:ok, state} <- maybe_run_brainstorm(state),
         {:ok, state} <- maybe_run_arbiter(state),
         {:ok, state} <- run_worker(state),
         {:ok, state} <- run_judge(state) do
      handle_judge_decision(state)
    else
      {:error, reason} ->
        Logger.error("Pipeline failed for #{state.issue.identifier} cycle=#{state.cycle}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_judge_decision(%{judge_decision: "accept"} = state) do
    Logger.info("Pipeline accepted for #{state.issue.identifier} at cycle=#{state.cycle}")
    :ok
  end

  defp handle_judge_decision(%{judge_decision: "replan"} = state) do
    Logger.info("Pipeline replanning for #{state.issue.identifier} cycle=#{state.cycle + 1}")
    send_progress(state, {:cycle_replan, state.cycle})

    state = %{state | cycle: state.cycle + 1, current_phase: :brainstorm, judge_decision: nil}
    run_cycle(state)
  end

  defp handle_judge_decision(%{judge_decision: "reject"} = state) do
    Logger.warning("Pipeline rejected for #{state.issue.identifier} at cycle=#{state.cycle}")
    {:error, {:judge_rejected, state.cycle}}
  end

  defp handle_judge_decision(state) do
    Logger.warning("Pipeline judge returned unknown decision=#{inspect(state.judge_decision)} for #{state.issue.identifier}")
    {:error, {:unknown_judge_decision, state.judge_decision}}
  end

  # --- Phase runners with artifact reuse ---

  defp maybe_run_brainstorm(state) do
    existing = Orchestration.list_proposals(state.workspace)
    valid_count = count_valid_proposals(existing)

    if valid_count >= 2 do
      Logger.info("Reusing #{valid_count} existing proposals for #{state.issue.identifier}")
      send_progress(state, {:phase_skipped, :brainstorm, :reused_artifacts})
      {:ok, state}
    else
      run_brainstorm(state)
    end
  end

  defp maybe_run_arbiter(state) do
    plan_path = Orchestration.plan_path(state.workspace)

    case Orchestration.validate_plan(plan_path) do
      {:ok, _plan} ->
        Logger.info("Reusing existing canonical plan for #{state.issue.identifier}")
        send_progress(state, {:phase_skipped, :arbiter, :reused_artifacts})
        {:ok, state}

      {:error, _} ->
        run_arbiter(state)
    end
  end

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
        cycle: state.cycle,
        total_cycles: state.max_cycles
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
        judge_path = Orchestration.judge_path(state.workspace)

        case Orchestration.validate_judge(judge_path) do
          {:ok, judge} ->
            case Orchestration.validate_judge_linear_evidence(judge) do
              :ok ->
                decision = Map.get(judge, "decision")
                state = complete_phase(state, :judge)
                {:ok, %{state | judge_decision: decision}}

              {:error, :missing_linear_evidence} ->
                {:error, {:judge_missing_linear_evidence, judge_path}}
            end

          {:error, reason} ->
            {:error, {:judge_invalid_artifact, reason}}
        end

      {:error, reason} ->
        {:error, {:judge_failed, reason}}
    end
  end

  defp count_valid_proposals(paths) do
    Enum.count(paths, fn path ->
      match?({:ok, _}, Orchestration.validate_proposal(path))
    end)
  end

  # --- Phase lifecycle ---

  defp enter_phase(state, phase) do
    Logger.info("Entering phase=#{phase} cycle=#{state.cycle} for #{state.issue.identifier}")
    send_progress(state, {:phase_started, phase, state.cycle})

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
    Logger.info("Completed phase=#{phase} cycle=#{state.cycle} for #{state.issue.identifier}")
    send_progress(state, {:phase_completed, phase, state.cycle})

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
