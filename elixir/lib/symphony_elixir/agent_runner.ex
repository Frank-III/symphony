defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with the configured coding agent runtime.
  """

  require Logger

  alias SymphonyElixir.{
    Config,
    Linear.Issue,
    OrchestrationFiles,
    PlanReview,
    PromptBuilder,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.Runtime.Profile, as: RuntimeProfile
  alias SymphonyElixir.Runtime.Registry, as: RuntimeRegistry

  defmodule Error do
    @moduledoc """
    Structured agent runner failure raised from worker task processes.
    """

    defexception [:reason, :message]

    @impl true
    def exception(opts) do
      reason = Keyword.fetch!(opts, :reason)
      %__MODULE__{reason: reason, message: "Agent run failed: #{inspect(reason)}"}
    end
  end

  @brainstorm_planner_attempts 2
  @artifact_poll_interval_ms 250
  @artifact_stop_grace_ms 1_000
  @planner_artifact_timeout_ms 20_000
  @arbiter_artifact_timeout_ms 20_000
  @codex_planner_artifact_timeout_ms 120_000
  @codex_arbiter_artifact_timeout_ms 120_000
  @artifact_completion_grace_ms 20_000
  @planner_artifact_activity_budget 6
  @arbiter_artifact_activity_budget 4

  @type worker_host :: String.t() | nil
  @type agent_role :: Config.agent_role()
  @type role_session :: %{
          backend: module(),
          role: agent_role(),
          runtime: String.t(),
          profile_name: String.t() | nil,
          provider: String.t() | nil,
          protocol: String.t() | nil,
          transport: String.t() | nil,
          display_name: String.t() | nil,
          session: term(),
          workspace: Path.t(),
          worker_host: worker_host(),
          cleanup_workspace: boolean()
        }

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, update_recipient \\ nil, opts \\ []) do
    worker_host =
      selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    worker_runtime = role_runtime(:worker, opts)
    orchestration_mode = Config.agent_orchestration_mode()

    Logger.info("Starting agent run for #{issue_context(issue)} worker_runtime=#{worker_runtime} orchestration_mode=#{orchestration_mode} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)} worker_runtime=#{worker_runtime} orchestration_mode=#{orchestration_mode}: #{inspect(reason)}")

        raise Error, reason: reason
    end
  end

  defp run_on_worker_host(issue, update_recipient, opts, worker_host) do
    Logger.info(
      "Starting worker attempt for #{issue_context(issue)} worker_runtime=#{role_runtime(:worker, opts)} orchestration_mode=#{Config.agent_orchestration_mode()} worker_host=#{worker_host_for_log(worker_host)}"
    )

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(update_recipient, issue, worker_host, workspace, opts)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_agent_turns(workspace, issue, update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_agent_turns(workspace, issue, update_recipient, opts, worker_host) do
    case Config.agent_orchestration_mode() do
      "brainstorm_arbiter_worker_judge" ->
        run_brainstorm_arbiter_worker_judge_cycles(
          workspace,
          issue,
          update_recipient,
          opts,
          worker_host
        )

      "planner_worker_judge" ->
        run_planner_worker_judge_cycles(workspace, issue, update_recipient, opts, worker_host)

      _other ->
        run_single_agent_turns(workspace, issue, update_recipient, opts, worker_host)
    end
  end

  defp run_single_agent_turns(workspace, issue, update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)

    issue_state_fetcher =
      Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, role_session} <- start_role_session(:worker, workspace, opts, worker_host) do
      try do
        do_run_single_agent_turns(
          role_session,
          workspace,
          issue,
          update_recipient,
          opts,
          issue_state_fetcher,
          1,
          max_turns
        )
      after
        stop_role_session(role_session)
      end
    end
  end

  defp do_run_single_agent_turns(
         role_session,
         workspace,
         issue,
         update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    with {:ok, turn_session} <-
           run_role_turn(
             role_session,
             workspace,
             issue,
             update_recipient,
             opts,
             turn_number,
             max_turns
           ) do
      Logger.info(
        "Completed agent run for #{issue_context(issue)} role=worker runtime=#{role_session.runtime} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}"
      )

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} role=worker runtime=#{role_session.runtime} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_single_agent_turns(
            role_session,
            workspace,
            refreshed_issue,
            update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} role=worker runtime=#{role_session.runtime} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_planner_worker_judge_cycles(workspace, issue, update_recipient, opts, worker_host) do
    max_cycles = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)

    issue_state_fetcher =
      Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with :ok <- OrchestrationFiles.prepare(workspace),
         {:ok, planner_session} <- start_role_session(:planner, workspace, opts, worker_host),
         {:ok, worker_session} <- start_role_session(:worker, workspace, opts, worker_host),
         {:ok, judge_session} <- start_role_session(:judge, workspace, opts, worker_host) do
      sessions = [planner_session, worker_session, judge_session]

      try do
        do_run_planner_worker_judge_cycles(
          planner_session,
          worker_session,
          judge_session,
          workspace,
          issue,
          update_recipient,
          opts,
          issue_state_fetcher,
          1,
          max_cycles
        )
      after
        Enum.each(sessions, &stop_role_session/1)
      end
    end
  end

  defp run_brainstorm_arbiter_worker_judge_cycles(
         workspace,
         issue,
         update_recipient,
         opts,
         worker_host
       ) do
    max_cycles = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)

    issue_state_fetcher =
      Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    planner_runtimes = Config.brainstorm_planner_runtimes()

    with :ok <- OrchestrationFiles.prepare(workspace),
         {:ok, arbiter_session} <- start_role_session(:arbiter, workspace, opts, worker_host),
         {:ok, worker_session} <- start_role_session(:worker, workspace, opts, worker_host),
         {:ok, judge_session} <- start_role_session(:judge, workspace, opts, worker_host) do
      sessions = [arbiter_session, worker_session, judge_session]

      try do
        do_run_brainstorm_arbiter_worker_judge_cycles(
          arbiter_session,
          worker_session,
          judge_session,
          planner_runtimes,
          workspace,
          issue,
          update_recipient,
          opts,
          worker_host,
          issue_state_fetcher,
          1,
          max_cycles
        )
      after
        Enum.each(sessions, &stop_role_session/1)
      end
    end
  end

  defp do_run_planner_worker_judge_cycles(
         planner_session,
         worker_session,
         judge_session,
         workspace,
         issue,
         update_recipient,
         opts,
         issue_state_fetcher,
         cycle,
         max_cycles
       ) do
    with :ok <- OrchestrationFiles.clear_plan(workspace),
         :ok <- OrchestrationFiles.clear_judge_result(workspace),
         {:ok, _planner_turn} <-
           run_role_turn(
             planner_session,
             workspace,
             issue,
             update_recipient,
             opts,
             cycle,
             max_cycles
           ),
         {:ok, _worker_turn} <-
           run_role_turn(
             worker_session,
             workspace,
             issue,
             update_recipient,
             opts,
             cycle,
             max_cycles
           ),
         {:ok, _judge_turn} <-
           run_role_turn(
             judge_session,
             workspace,
             issue,
             update_recipient,
             opts,
             cycle,
             max_cycles
           ) do
      case orchestration_decision(workspace, issue, issue_state_fetcher, update_recipient) do
        {:continue, refreshed_issue} when cycle < max_cycles ->
          Logger.info("Continuing planner/worker/judge cycle for #{issue_context(refreshed_issue)} cycle=#{cycle}/#{max_cycles}")

          do_run_planner_worker_judge_cycles(
            planner_session,
            worker_session,
            judge_session,
            workspace,
            refreshed_issue,
            update_recipient,
            opts,
            issue_state_fetcher,
            cycle + 1,
            max_cycles
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with orchestration_mode=planner_worker_judge while the issue remains active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:blocked, refreshed_issue} ->
          Logger.info("Judge ended planner/worker/judge cycle for #{issue_context(refreshed_issue)} with a blocked decision")

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_run_brainstorm_arbiter_worker_judge_cycles(
         arbiter_session,
         worker_session,
         judge_session,
         planner_runtimes,
         workspace,
         issue,
         update_recipient,
         opts,
         worker_host,
         issue_state_fetcher,
         cycle,
         max_cycles
       ) do
    if resume_plan_review?(workspace, issue) do
      resume_brainstorm_worker_and_judge_cycle(
        arbiter_session,
        worker_session,
        judge_session,
        planner_runtimes,
        workspace,
        issue,
        update_recipient,
        opts,
        worker_host,
        issue_state_fetcher,
        cycle,
        max_cycles
      )
    else
      with :ok <- OrchestrationFiles.clear_plan_review(workspace),
           :ok <- OrchestrationFiles.clear_plan(workspace),
           :ok <- OrchestrationFiles.clear_judge_result(workspace),
           :ok <- OrchestrationFiles.clear_proposals(workspace),
           :ok <-
             run_brainstorm_planner_turns(
               planner_runtimes,
               workspace,
               issue,
               update_recipient,
               opts,
               worker_host,
               cycle,
               max_cycles
             ),
           {:ok, plan_result} <-
             run_arbiter_turn(
               arbiter_session,
               length(planner_runtimes),
               workspace,
               issue,
               update_recipient,
               opts,
               cycle,
               max_cycles
             ),
           :ok <-
             maybe_request_plan_review(
               workspace,
               issue,
               plan_result,
               update_recipient,
               cycle,
               max_cycles
             ) do
        if Config.agent_plan_review_required?() do
          :ok
        else
          resume_brainstorm_worker_and_judge_cycle(
            arbiter_session,
            worker_session,
            judge_session,
            planner_runtimes,
            workspace,
            issue,
            update_recipient,
            opts,
            worker_host,
            issue_state_fetcher,
            cycle,
            max_cycles
          )
        end
      end
    end
  end

  defp resume_brainstorm_worker_and_judge_cycle(
         arbiter_session,
         worker_session,
         judge_session,
         planner_runtimes,
         workspace,
         issue,
         update_recipient,
         opts,
         worker_host,
         issue_state_fetcher,
         cycle,
         max_cycles
       ) do
    with :ok <- OrchestrationFiles.clear_judge_result(workspace),
         {:ok, _worker_turn} <-
           run_role_turn(
             worker_session,
             workspace,
             issue,
             update_recipient,
             opts,
             cycle,
             max_cycles
           ),
         {:ok, _judge_turn} <-
           run_role_turn(
             judge_session,
             workspace,
             issue,
             update_recipient,
             opts,
             cycle,
             max_cycles
           ),
         :ok <- OrchestrationFiles.clear_plan_review(workspace) do
      case orchestration_decision(workspace, issue, issue_state_fetcher, update_recipient) do
        {:continue, refreshed_issue} when cycle < max_cycles ->
          Logger.info("Continuing brainstorm/arbiter/worker/judge cycle for #{issue_context(refreshed_issue)} cycle=#{cycle}/#{max_cycles}")

          do_run_brainstorm_arbiter_worker_judge_cycles(
            arbiter_session,
            worker_session,
            judge_session,
            planner_runtimes,
            workspace,
            refreshed_issue,
            update_recipient,
            opts,
            worker_host,
            issue_state_fetcher,
            cycle + 1,
            max_cycles
          )

        {:continue, refreshed_issue} ->
          Logger.info(
            "Reached agent.max_turns for #{issue_context(refreshed_issue)} with orchestration_mode=brainstorm_arbiter_worker_judge while the issue remains active; returning control to orchestrator"
          )

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:blocked, refreshed_issue} ->
          Logger.info("Judge ended brainstorm/arbiter/worker/judge cycle for #{issue_context(refreshed_issue)} with a blocked decision")

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_brainstorm_planner_turns(
         planner_runtimes,
         workspace,
         issue,
         update_recipient,
         opts,
         worker_host,
         cycle,
         max_cycles
       ) do
    planner_count = length(planner_runtimes)

    planner_runtimes
    |> Enum.with_index(1)
    |> Enum.map(fn {planner_runtime, planner_index} ->
      task =
        Task.async(fn ->
          run_brainstorm_planner_turn_with_retries(
            planner_index,
            planner_count,
            planner_runtime,
            workspace,
            issue,
            update_recipient,
            opts,
            worker_host,
            cycle,
            max_cycles,
            @brainstorm_planner_attempts
          )
        end)

      {planner_index, task}
    end)
    |> Enum.map(fn {planner_index, task} ->
      try do
        {planner_index, Task.await(task, :infinity)}
      catch
        :exit, reason -> {planner_index, {:error, {:planner_turn_crashed, reason}}}
      end
    end)
    |> finalize_brainstorm_planner_results(
      issue,
      update_recipient,
      planner_count,
      cycle,
      max_cycles
    )
  end

  defp run_brainstorm_planner_turn_with_retries(
         planner_index,
         planner_count,
         planner_runtime,
         workspace,
         issue,
         update_recipient,
         opts,
         worker_host,
         cycle,
         max_cycles,
         attempts_remaining,
         last_reason \\ nil
       )
       when attempts_remaining > 0 do
    with {:ok, planner_workspace} <-
           Workspace.create_brainstorm_planner_workspace(workspace, planner_index, worker_host),
         :ok <- OrchestrationFiles.prepare(planner_workspace),
         :ok <- OrchestrationFiles.clear_proposals(planner_workspace),
         :ok <- OrchestrationFiles.clear_judge_result(planner_workspace),
         :ok <- OrchestrationFiles.seed_proposal_draft(planner_workspace, planner_index, cycle),
         {:ok, planner_session} <-
           start_role_session(
             :planner,
             planner_workspace,
             opts,
             worker_host,
             cleanup_workspace: true,
             role_opts: [planner_index: planner_index, runtime: planner_runtime]
           ) do
      try do
        planner_attempt = @brainstorm_planner_attempts - attempts_remaining + 1

        role_opts =
          [
            planner_count: planner_count,
            planner_index: planner_index,
            planner_attempt: planner_attempt,
            retry_reason: last_reason
          ]

        maybe_stagger_brainstorm_planner_start(planner_index)

        with :ok <-
               run_brainstorm_planner_turn_until_artifact(
                 planner_session,
                 workspace,
                 issue,
                 update_recipient,
                 opts,
                 cycle,
                 max_cycles,
                 role_opts
               ),
             :ok <- sync_planner_proposal(planner_session, workspace, planner_index),
             :ok <- ensure_planner_proposal_exists(workspace, planner_index) do
          :ok
        else
          {:error, reason} ->
            maybe_retry_brainstorm_planner_turn(
              planner_index,
              planner_count,
              planner_runtime,
              workspace,
              issue,
              update_recipient,
              opts,
              worker_host,
              cycle,
              max_cycles,
              attempts_remaining,
              reason
            )
        end
      after
        stop_role_session(planner_session)
      end
    else
      {:error, reason} ->
        maybe_retry_brainstorm_planner_turn(
          planner_index,
          planner_count,
          planner_runtime,
          workspace,
          issue,
          update_recipient,
          opts,
          worker_host,
          cycle,
          max_cycles,
          attempts_remaining,
          reason
        )
    end
  end

  defp maybe_retry_brainstorm_planner_turn(
         planner_index,
         planner_count,
         planner_runtime,
         workspace,
         issue,
         update_recipient,
         opts,
         worker_host,
         cycle,
         max_cycles,
         attempts_remaining,
         reason
       ) do
    if attempts_remaining > 1 and retryable_brainstorm_planner_error?(reason) do
      emit_role_event(update_recipient, issue, :planner, :planner_retrying, %{
        cycle: cycle,
        max_cycles: max_cycles,
        planner_index: planner_index,
        planner_count: planner_count,
        attempts_remaining: attempts_remaining - 1,
        reason: reason
      })

      Logger.warning(
        "Retrying brainstorm planner for #{issue_context(issue)} planner_index=#{planner_index} cycle=#{cycle}/#{max_cycles} attempts_remaining=#{attempts_remaining - 1} reason=#{inspect(reason)}"
      )

      run_brainstorm_planner_turn_with_retries(
        planner_index,
        planner_count,
        planner_runtime,
        workspace,
        issue,
        update_recipient,
        opts,
        worker_host,
        cycle,
        max_cycles,
        attempts_remaining - 1,
        reason
      )
    else
      {:error, reason}
    end
  end

  defp retryable_brainstorm_planner_error?({:planner_turn_crashed, _reason}), do: true
  defp retryable_brainstorm_planner_error?({:port_exit, _status}), do: true

  defp retryable_brainstorm_planner_error?({:response_timeout, _request_name, _timeout_ms}),
    do: true

  defp retryable_brainstorm_planner_error?({:response_timeout, _request_name, _timeout_ms, _metadata}),
    do: true

  defp retryable_brainstorm_planner_error?({:artifact_timeout, _artifact_path, _timeout_ms}),
    do: true

  defp retryable_brainstorm_planner_error?({:artifact_incomplete_after_turn, _artifact_path, _reason}),
    do: true

  defp retryable_brainstorm_planner_error?({:artifact_watchdog_triggered, _artifact_path, _activity_count, _activity_budget, _event}),
    do: true

  defp retryable_brainstorm_planner_error?(:turn_timeout), do: true
  defp retryable_brainstorm_planner_error?(_reason), do: false

  defp finalize_brainstorm_planner_results(
         results,
         issue,
         update_recipient,
         planner_count,
         cycle,
         max_cycles
       ) do
    {successful_results, failed_results} =
      Enum.split_with(results, fn {_planner_index, result} -> result == :ok end)

    Enum.each(failed_results, fn {planner_index, {:error, reason}} ->
      emit_role_event(update_recipient, issue, :planner, :planner_failed, %{
        cycle: cycle,
        max_cycles: max_cycles,
        planner_index: planner_index,
        planner_count: planner_count,
        reason: reason
      })

      Logger.warning("Brainstorm planner failed for #{issue_context(issue)} planner_index=#{planner_index} cycle=#{cycle}/#{max_cycles} reason=#{inspect(reason)}")
    end)

    case successful_results do
      [] ->
        case failed_results do
          [{_planner_index, {:error, reason}} | _] -> {:error, reason}
          _ -> {:error, :planner_wave_failed}
        end

      _ ->
        :ok
    end
  end

  defp maybe_stagger_brainstorm_planner_start(planner_index)
       when is_integer(planner_index) and planner_index > 1 do
    Process.sleep((planner_index - 1) * 1_500)
  end

  defp maybe_stagger_brainstorm_planner_start(_planner_index), do: :ok

  defp ensure_planner_proposal_exists(workspace, planner_index)
       when is_binary(workspace) and is_integer(planner_index) and planner_index > 0 do
    proposal_path = OrchestrationFiles.proposal_path(workspace, planner_index)

    if OrchestrationFiles.artifact_ready?(proposal_path) do
      :ok
    else
      {:error, {:planner_proposal_missing, planner_index}}
    end
  end

  defp run_arbiter_turn(
         arbiter_session,
         planner_count,
         workspace,
         issue,
         update_recipient,
         opts,
         cycle,
         max_cycles
       ) do
    role_opts = [planner_count: planner_count]

    artifact_timeout_ms =
      case Keyword.fetch(opts, :arbiter_artifact_timeout_ms) do
        {:ok, timeout_ms} -> timeout_ms
        :error -> default_artifact_timeout_ms(:arbiter, arbiter_session)
      end

    artifact_completion_grace_ms =
      Keyword.get(opts, :artifact_completion_grace_ms, @artifact_completion_grace_ms)

    with :ok <- OrchestrationFiles.seed_plan_draft(workspace, cycle),
         :ok <-
           run_role_turn_until_artifact(
             arbiter_session,
             workspace,
             issue,
             update_recipient,
             opts,
             cycle,
             max_cycles,
             role_opts,
             OrchestrationFiles.plan_path(workspace),
             artifact_timeout_ms,
             artifact_completion_grace_ms
           ),
         {:ok, plan_result} <- OrchestrationFiles.load_plan(workspace) do
      emit_role_event(update_recipient, issue, :arbiter, :arbiter_plan_selected, %{
        cycle: cycle,
        max_cycles: max_cycles,
        planner_count: planner_count,
        payload: plan_result.raw,
        summary: normalize_plan_judge_summary(plan_result.summary),
        task_count: plan_result.task_count,
        next_task_id: plan_result.next_task_id
      })

      {:ok, plan_result}
    else
      {:error, reason} ->
        emit_role_event(update_recipient, issue, :arbiter, :arbiter_plan_missing, %{
          cycle: cycle,
          max_cycles: max_cycles,
          planner_count: planner_count,
          reason: reason
        })

        {:error, reason}
    end
  end

  defp start_role_session(role, workspace, opts, worker_host) do
    start_role_session(role, workspace, opts, worker_host, [])
  end

  defp start_role_session(role, workspace, opts, worker_host, session_opts) do
    role_opts = Keyword.get(session_opts, :role_opts, [])
    cleanup_workspace = Keyword.get(session_opts, :cleanup_workspace, false)

    case Keyword.get(opts, :"#{role}_backend_module") do
      nil ->
        with {:ok, profile} <- resolve_role_profile(role, opts, role_opts),
             adapter = profile.adapter_module,
             backend_opts <- role_backend_start_opts(role, opts, worker_host, role_opts, profile),
             {:ok, session} <- adapter.start_session(profile.config, workspace, backend_opts) do
          {:ok,
           %{
             backend: adapter,
             role: role,
             runtime: profile_runtime_name(profile),
             profile_name: profile_name(profile),
             provider: profile_provider(profile),
             protocol: profile_protocol(profile),
             transport: profile_transport(profile),
             display_name: profile_display_name(profile),
             session: session,
             workspace: workspace,
             worker_host: worker_host,
             cleanup_workspace: cleanup_workspace
           }}
        end

      backend when is_atom(backend) ->
        backend_opts = role_backend_start_opts(role, opts, worker_host, role_opts, nil)

        with {:ok, session} <- backend.start_session(workspace, backend_opts) do
          {:ok,
           %{
             backend: backend,
             role: role,
             runtime: role_runtime(role, opts, role_opts),
             profile_name: nil,
             provider: nil,
             protocol: nil,
             transport: nil,
             display_name: nil,
             session: session,
             workspace: workspace,
             worker_host: worker_host,
             cleanup_workspace: cleanup_workspace
           }}
        end
    end
  end

  defp stop_role_session(%{backend: backend, session: session} = role_session) do
    backend.stop_session(session)

    if role_session.cleanup_workspace do
      Workspace.remove_ephemeral(role_session.workspace, role_session.worker_host)
    end
  end

  defp stop_role_session(_role_session), do: :ok

  defp run_role_turn(
         role_session,
         workspace,
         issue,
         update_recipient,
         opts,
         cycle,
         max_cycles,
         role_opts \\ []
       ) do
    role = role_session.role
    role_workspace = Map.get(role_session, :workspace, workspace)
    role_payload = role_metadata_payload(role_opts)

    emit_role_event(
      update_recipient,
      issue,
      role,
      :role_started,
      %{
        cycle: cycle,
        max_cycles: max_cycles,
        runtime: role_session.runtime
      }
      |> maybe_put_role_runtime_value(:profile_name, Map.get(role_session, :profile_name))
      |> maybe_put_role_runtime_value(:provider, Map.get(role_session, :provider))
      |> maybe_put_role_runtime_value(:protocol, Map.get(role_session, :protocol))
      |> maybe_put_role_runtime_value(:transport, Map.get(role_session, :transport))
      |> maybe_put_role_runtime_value(:display_name, Map.get(role_session, :display_name))
      |> Map.merge(role_payload)
    )

    prompt =
      build_turn_prompt(
        issue,
        opts,
        role,
        cycle,
        max_cycles,
        role_session.runtime,
        role_workspace,
        Config.agent_orchestration_mode(),
        role_opts
      )

    role_turn_opts =
      Keyword.merge(
        role_backend_turn_opts(role, opts, role_opts),
        cycle: cycle,
        max_cycles: max_cycles,
        on_message: agent_message_handler(update_recipient, issue, role, role_payload),
        role: role
      )
      |> Keyword.merge(role_opts)

    role_session.backend.run_turn(role_session.session, prompt, issue, role_turn_opts)
  end

  defp sync_planner_proposal(planner_session, base_workspace, planner_index) do
    Workspace.copy_file(
      OrchestrationFiles.proposal_path(planner_session.workspace, planner_index),
      OrchestrationFiles.proposal_path(base_workspace, planner_index),
      planner_session.worker_host
    )
  end

  defp run_brainstorm_planner_turn_until_artifact(
         planner_session,
         workspace,
         issue,
         update_recipient,
         opts,
         cycle,
         max_cycles,
         role_opts
       ) do
    proposal_path =
      OrchestrationFiles.proposal_path(
        planner_session.workspace,
        Keyword.fetch!(role_opts, :planner_index)
      )

    artifact_timeout_ms =
      case Keyword.fetch(opts, :planner_artifact_timeout_ms) do
        {:ok, timeout_ms} -> timeout_ms
        :error -> default_artifact_timeout_ms(:planner, planner_session)
      end

    artifact_completion_grace_ms =
      Keyword.get(opts, :artifact_completion_grace_ms, @artifact_completion_grace_ms)

    run_role_turn_until_artifact(
      planner_session,
      workspace,
      issue,
      update_recipient,
      opts,
      cycle,
      max_cycles,
      role_opts,
      proposal_path,
      artifact_timeout_ms,
      artifact_completion_grace_ms
    )
  end

  defp run_role_turn_until_artifact(
         role_session,
         workspace,
         issue,
         update_recipient,
         opts,
         cycle,
         max_cycles,
         role_opts,
         artifact_path,
         artifact_timeout_ms,
         artifact_completion_grace_ms
       ) do
    watchdog_ref = make_ref()
    progress_ref = :atomics.new(1, [])

    role_opts = Keyword.put_new(role_opts, :cycle, cycle)

    role_opts =
      Keyword.put(
        role_opts,
        :on_message,
        artifact_watchdog_message_handler(
          update_recipient,
          issue,
          role_session,
          artifact_path,
          role_opts,
          watchdog_ref,
          progress_ref
        )
      )

    turn_task =
      Task.async(fn ->
        run_role_turn(
          role_session,
          workspace,
          issue,
          update_recipient,
          opts,
          cycle,
          max_cycles,
          role_opts
        )
      end)

    case await_role_turn_artifact(
           turn_task,
           artifact_path,
           artifact_timeout_ms,
           artifact_completion_grace_ms,
           watchdog_ref,
           progress_ref
         ) do
      {:ok, _result} ->
        :ok

      {:artifact_ready, task} ->
        role_session.backend.stop_session(role_session.session)
        _ = Task.shutdown(task, @artifact_stop_grace_ms)
        :ok

      {:error, reason} ->
        _ = Task.shutdown(turn_task, @artifact_stop_grace_ms)
        {:error, reason}
    end
  end

  defp await_role_turn_artifact(
         turn_task,
         artifact_path,
         artifact_timeout_ms,
         artifact_completion_grace_ms,
         watchdog_ref,
         progress_ref
       )
       when is_binary(artifact_path) and is_integer(artifact_timeout_ms) and artifact_timeout_ms > 0 do
    started_at_ms = System.monotonic_time(:millisecond)

    do_await_role_turn_artifact(
      turn_task,
      artifact_path,
      artifact_timeout_ms,
      artifact_completion_grace_ms,
      started_at_ms,
      watchdog_ref,
      progress_ref
    )
  end

  defp do_await_role_turn_artifact(
         turn_task,
         artifact_path,
         artifact_timeout_ms,
         artifact_completion_grace_ms,
         started_at_ms,
         watchdog_ref,
         progress_ref
       ) do
    case artifact_watchdog_signal(watchdog_ref) do
      {:triggered, reason} ->
        {:error, reason}

      :continue ->
        case Task.yield(turn_task, 0) do
          {:ok, {:ok, turn_result}} ->
            if OrchestrationFiles.artifact_ready?(artifact_path) do
              {:ok, :completed}
            else
              case maybe_materialize_artifact_from_turn_result(artifact_path, turn_result) do
                :ok ->
                  {:ok, :materialized_from_turn_result}

                {:error, reason} ->
                  {:error, {:artifact_incomplete_after_turn, artifact_path, reason}}
              end
            end

          {:ok, {:error, reason}} ->
            {:error, reason}

          nil ->
            if OrchestrationFiles.artifact_ready?(artifact_path) do
              {:artifact_ready, turn_task}
            else
              timeout_started_at_ms = artifact_timeout_started_at_ms(progress_ref, started_at_ms)

              if System.monotonic_time(:millisecond) - timeout_started_at_ms >= artifact_timeout_ms do
                await_role_turn_completion_fallback(
                  turn_task,
                  artifact_path,
                  artifact_completion_grace_ms,
                  watchdog_ref,
                  progress_ref
                )
              else
                Process.sleep(@artifact_poll_interval_ms)

                do_await_role_turn_artifact(
                  turn_task,
                  artifact_path,
                  artifact_timeout_ms,
                  artifact_completion_grace_ms,
                  started_at_ms,
                  watchdog_ref,
                  progress_ref
                )
              end
            end
        end
    end
  end

  defp await_role_turn_completion_fallback(
         turn_task,
         artifact_path,
         artifact_completion_grace_ms,
         watchdog_ref,
         progress_ref
       ) do
    fallback_started_at_ms = System.monotonic_time(:millisecond)

    do_await_role_turn_completion_fallback(
      turn_task,
      artifact_path,
      artifact_completion_grace_ms,
      fallback_started_at_ms,
      watchdog_ref,
      progress_ref
    )
  end

  defp do_await_role_turn_completion_fallback(
         turn_task,
         artifact_path,
         artifact_completion_grace_ms,
         fallback_started_at_ms,
         watchdog_ref,
         progress_ref
       ) do
    case artifact_watchdog_signal(watchdog_ref) do
      {:triggered, reason} ->
        {:error, reason}

      :continue ->
        case Task.yield(turn_task, 0) do
          {:ok, {:ok, turn_result}} ->
            if OrchestrationFiles.artifact_ready?(artifact_path) do
              {:ok, :completed}
            else
              case maybe_materialize_artifact_from_turn_result(artifact_path, turn_result) do
                :ok ->
                  {:ok, :materialized_from_turn_result}

                {:error, reason} ->
                  {:error, {:artifact_incomplete_after_turn, artifact_path, reason}}
              end
            end

          {:ok, {:error, reason}} ->
            {:error, reason}

          nil ->
            if System.monotonic_time(:millisecond) - fallback_started_at_ms >=
                 artifact_completion_grace_ms do
              {:error, {:artifact_timeout, artifact_path, artifact_completion_grace_ms}}
            else
              Process.sleep(@artifact_poll_interval_ms)

              do_await_role_turn_completion_fallback(
                turn_task,
                artifact_path,
                artifact_completion_grace_ms,
                fallback_started_at_ms,
                watchdog_ref,
                progress_ref
              )
            end
        end
    end
  end

  defp artifact_timeout_started_at_ms(progress_ref, default_started_at_ms) do
    case :atomics.get(progress_ref, 1) do
      progress_at_ms when is_integer(progress_at_ms) and progress_at_ms > 0 -> progress_at_ms
      _other -> default_started_at_ms
    end
  end

  defp default_artifact_timeout_ms(:planner, %{provider: "codex"}),
    do: @codex_planner_artifact_timeout_ms

  defp default_artifact_timeout_ms(:arbiter, %{provider: "codex"}),
    do: @codex_arbiter_artifact_timeout_ms

  defp default_artifact_timeout_ms(:planner, runtime) when is_binary(runtime) do
    if String.starts_with?(runtime, "codex") do
      @codex_planner_artifact_timeout_ms
    else
      @planner_artifact_timeout_ms
    end
  end

  defp default_artifact_timeout_ms(:arbiter, runtime) when is_binary(runtime) do
    if String.starts_with?(runtime, "codex") do
      @codex_arbiter_artifact_timeout_ms
    else
      @arbiter_artifact_timeout_ms
    end
  end

  defp default_artifact_timeout_ms(:planner, _runtime), do: @planner_artifact_timeout_ms
  defp default_artifact_timeout_ms(:arbiter, _runtime), do: @arbiter_artifact_timeout_ms

  defp maybe_materialize_artifact_from_turn_result(artifact_path, turn_result)
       when is_binary(artifact_path) do
    turn_result
    |> artifact_materialization_candidates()
    |> Enum.reduce_while({:error, :artifact_result_missing_json}, fn candidate, _acc ->
      case OrchestrationFiles.materialize_artifact(artifact_path, candidate) do
        :ok -> {:halt, :ok}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp artifact_materialization_candidates(turn_result) do
    [
      turn_result,
      get_if_map(turn_result, :result),
      get_if_map(turn_result, "result"),
      get_if_map(turn_result, :final_answer),
      get_if_map(turn_result, "final_answer"),
      get_if_map(turn_result, :last_agent_message),
      get_if_map(turn_result, "last_agent_message"),
      get_if_map(turn_result, :raw_result),
      get_if_map(turn_result, "raw_result")
    ]
    |> Enum.flat_map(&flatten_artifact_materialization_candidate/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp flatten_artifact_materialization_candidate(%{} = candidate) do
    [
      candidate,
      Map.get(candidate, :result),
      Map.get(candidate, "result"),
      Map.get(candidate, :final_answer),
      Map.get(candidate, "final_answer"),
      Map.get(candidate, :last_agent_message),
      Map.get(candidate, "last_agent_message"),
      Map.get(candidate, :payload),
      Map.get(candidate, "payload")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp flatten_artifact_materialization_candidate(candidate), do: [candidate]

  defp get_if_map(%{} = map, key), do: Map.get(map, key)
  defp get_if_map(_other, _key), do: nil

  defp artifact_watchdog_signal(watchdog_ref) do
    receive do
      {:artifact_watchdog_triggered, ^watchdog_ref, reason} -> {:triggered, reason}
    after
      0 -> :continue
    end
  end

  defp orchestration_decision(workspace, issue, issue_state_fetcher, update_recipient) do
    issue_state =
      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} -> {:continue, refreshed_issue}
        {:done, refreshed_issue} -> {:done, refreshed_issue}
        {:error, reason} -> {:error, reason}
      end

    case OrchestrationFiles.load_judge_result(workspace) do
      {:ok, judge_result} ->
        emit_role_event(update_recipient, issue, :judge, :judge_decision, %{
          decision: judge_result.decision,
          payload: judge_result.raw,
          summary: judge_result.summary,
          next_focus: judge_result.next_focus
        })

        case issue_state do
          {:continue, refreshed_issue} ->
            maybe_log_active_judge_stop(judge_result.decision, refreshed_issue)

            case judge_result.decision do
              :continue -> {:continue, refreshed_issue}
              :done -> {:done, refreshed_issue}
              :blocked -> {:blocked, refreshed_issue}
            end

          {:done, refreshed_issue} ->
            {:done, refreshed_issue}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Judge result unavailable for #{issue_context(issue)} workspace=#{workspace}: #{inspect(reason)}; falling back to Linear issue state")

        emit_role_event(update_recipient, issue, :judge, :judge_decision_missing, %{
          reason: reason
        })

        issue_state
    end
  end

  defp maybe_request_plan_review(
         workspace,
         issue,
         plan_result,
         update_recipient,
         cycle,
         max_cycles
       ) do
    if Config.agent_plan_review_required?() do
      review_body =
        PlanReview.render(
          issue,
          plan_result,
          cycle: cycle,
          review_state: PlanReview.review_state()
        )

      review_payload = %{
        version: 1,
        cycle: cycle,
        review_state: PlanReview.review_state(),
        resume_state: PlanReview.resume_state(),
        marker: PlanReview.marker()
      }

      with :ok <- Tracker.upsert_comment(issue.id, PlanReview.marker(), review_body),
           :ok <- OrchestrationFiles.write_plan_review(workspace, review_payload),
           :ok <- Tracker.update_issue_state(issue.id, PlanReview.review_state()) do
        emit_role_event(update_recipient, issue, :arbiter, :plan_review_requested, %{
          cycle: cycle,
          max_cycles: max_cycles,
          review_state: PlanReview.review_state(),
          resume_state: PlanReview.resume_state(),
          summary: normalize_plan_judge_summary(plan_result.summary),
          payload: plan_result.raw
        })

        Logger.info("Paused after plan judge for #{issue_context(issue)} review_state=#{PlanReview.review_state()} resume_state=#{PlanReview.resume_state()}")

        :ok
      end
    else
      :ok
    end
  end

  defp resume_plan_review?(workspace, %Issue{state: state})
       when is_binary(workspace) and is_binary(state) do
    case OrchestrationFiles.load_plan_review(workspace) do
      {:ok, _payload} ->
        normalize_issue_state(state) == normalize_issue_state(PlanReview.resume_state())

      {:error, :plan_review_missing} ->
        false

      {:error, _reason} ->
        false
    end
  end

  defp resume_plan_review?(_workspace, _issue), do: false

  defp maybe_log_active_judge_stop(:continue, _issue), do: :ok

  defp maybe_log_active_judge_stop(decision, issue) do
    Logger.warning("Judge requested #{decision} for #{issue_context(issue)} while the issue is still active; update the tracker state during the judge turn to avoid immediate redispatch")
  end

  defp build_turn_prompt(
         _issue,
         _opts,
         :worker,
         turn_number,
         max_turns,
         runtime,
         _workspace,
         "single",
         _role_opts
       )
       when turn_number > 1 do
    continuation_prompt(runtime, turn_number, max_turns)
  end

  defp build_turn_prompt(
         issue,
         opts,
         role,
         cycle,
         max_cycles,
         runtime,
         workspace,
         orchestration_mode,
         role_opts
       ) do
    PromptBuilder.build_prompt(
      issue,
      attempt:
        Keyword.get(role_opts, :planner_attempt) ||
          Keyword.get(opts, :attempt),
      cycle: cycle,
      max_cycles: max_cycles,
      orchestration_mode: orchestration_mode,
      planner_count: Keyword.get(role_opts, :planner_count),
      planner_index: Keyword.get(role_opts, :planner_index),
      retry_reason: Keyword.get(role_opts, :retry_reason),
      role: role,
      runtime: runtime,
      workspace: workspace
    )
  end

  defp continuation_prompt(runtime, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous agent turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current #{runtime} worker run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp agent_message_handler(recipient, issue, role, role_payload) do
    fn message ->
      send_agent_update(recipient, issue, Map.merge(Map.put(message, :role, role), role_payload))
    end
  end

  defp artifact_watchdog_message_handler(
         recipient,
         issue,
         role_session,
         artifact_path,
         role_opts,
         watchdog_ref,
         progress_ref
       ) do
    role = role_session.role
    role_payload = role_metadata_payload(role_opts)
    delegate = agent_message_handler(recipient, issue, role, role_payload)
    watchdog_recipient = self()
    activity_budget = artifact_activity_budget(role)
    counter_ref = :atomics.new(2, [])

    fn message ->
      delegate.(message)
      note_artifact_progress(progress_ref)

      maybe_materialize_artifact_from_tool_message(
        recipient,
        issue,
        role,
        role_opts,
        message,
        artifact_path
      )

      if artifact_write_first_violation?(role, message, artifact_path) do
        event = Map.get(message, :event)
        tool_name = Map.get(message, :tool_name)
        reason = {:artifact_write_first_violation, artifact_path, tool_name, event}

        emit_role_event(recipient, issue, role, :artifact_write_first_violation, %{
          artifact_path: artifact_path,
          cycle: Keyword.get(role_opts, :cycle),
          activity_event: event,
          tool_name: tool_name
        })

        role_session.backend.stop_session(role_session.session)
        send(watchdog_recipient, {:artifact_watchdog_triggered, watchdog_ref, reason})
      end

      if artifact_watchdog_activity_event?(message) and is_integer(activity_budget) and
           activity_budget > 0 and not OrchestrationFiles.artifact_ready?(artifact_path) do
        activity_count = :atomics.add_get(counter_ref, 1, 1)
        already_triggered? = :atomics.get(counter_ref, 2) == 1

        if activity_count >= activity_budget and not already_triggered? do
          :atomics.put(counter_ref, 2, 1)
          role_session.backend.stop_session(role_session.session)

          event = Map.get(message, :event)

          reason =
            {:artifact_watchdog_triggered, artifact_path, activity_count, activity_budget, event}

          emit_role_event(recipient, issue, role, :artifact_watchdog_triggered, %{
            activity_budget: activity_budget,
            activity_count: activity_count,
            artifact_path: artifact_path,
            cycle: Keyword.get(role_opts, :cycle),
            activity_event: event
          })

          send(watchdog_recipient, {:artifact_watchdog_triggered, watchdog_ref, reason})
        end
      end

      :ok
    end
  end

  defp artifact_activity_budget(:planner), do: @planner_artifact_activity_budget
  defp artifact_activity_budget(:arbiter), do: @arbiter_artifact_activity_budget
  defp artifact_activity_budget(_role), do: nil

  defp note_artifact_progress(progress_ref) do
    now_ms = System.monotonic_time(:millisecond)

    _ =
      :atomics.compare_exchange(progress_ref, 1, 0, now_ms)

    :ok
  end

  defp artifact_watchdog_activity_event?(%{event: :tool_use_summary}), do: true

  defp artifact_watchdog_activity_event?(%{event: :agent_activity, tool_name: tool_name})
       when is_binary(tool_name),
       do: true

  defp artifact_watchdog_activity_event?(_message), do: false

  defp artifact_write_first_violation?(role, %{tool_name: tool_name}, artifact_path)
       when role in [:planner, :arbiter] and
              tool_name in ["Glob", "Grep", "NotebookEdit"] and
              is_binary(artifact_path) do
    not OrchestrationFiles.artifact_ready?(artifact_path)
  end

  defp artifact_write_first_violation?(
         :planner,
         %{tool_name: "Read", tool_file_path: file_path},
         artifact_path
       )
       when is_binary(file_path) and is_binary(artifact_path) do
    not OrchestrationFiles.artifact_ready?(artifact_path) and
      not allowed_artifact_prewrite_read_path?(file_path, artifact_path)
  end

  defp artifact_write_first_violation?(_role, _message, _artifact_path), do: false

  defp allowed_artifact_prewrite_read_path?(file_path, artifact_path)
       when is_binary(file_path) and is_binary(artifact_path) do
    expanded_file_path = Path.expand(file_path)
    expanded_artifact_path = Path.expand(artifact_path)
    artifact_directory = Path.dirname(expanded_artifact_path)
    orchestration_directory = Path.dirname(artifact_directory)

    expanded_file_path in [expanded_artifact_path, artifact_directory, orchestration_directory]
  end

  defp maybe_materialize_artifact_from_tool_message(
         recipient,
         issue,
         role,
         role_opts,
         %{tool_name: "Write", tool_file_path: tool_file_path, tool_content: tool_content},
         artifact_path
       )
       when role in [:planner, :arbiter] and is_binary(tool_file_path) and is_binary(tool_content) and
              is_binary(artifact_path) do
    if not OrchestrationFiles.artifact_ready?(artifact_path) and
         Path.expand(tool_file_path) == Path.expand(artifact_path) do
      case OrchestrationFiles.materialize_artifact(artifact_path, tool_content) do
        :ok ->
          emit_role_event(recipient, issue, role, :artifact_materialized_from_tool_message, %{
            artifact_path: artifact_path,
            cycle: Keyword.get(role_opts, :cycle),
            tool_name: "Write"
          })

        {:error, _reason} ->
          :ok
      end
    end

    :ok
  end

  defp maybe_materialize_artifact_from_tool_message(
         _recipient,
         _issue,
         _role,
         _role_opts,
         _message,
         _artifact_path
       ),
       do: :ok

  defp emit_role_event(recipient, issue, role, event, payload) do
    send_agent_update(
      recipient,
      issue,
      %{
        event: event,
        timestamp: DateTime.utc_now(),
        role: role
      }
      |> Map.merge(payload)
    )
  end

  defp role_metadata_payload(role_opts) when is_list(role_opts) do
    role_opts
    |> Keyword.take([:planner_count, :planner_index])
    |> Enum.into(%{})
  end

  defp send_agent_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_agent_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace, opts)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    runtime_profile = resolve_worker_runtime_profile(opts)

    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         orchestration_mode: Config.agent_orchestration_mode(),
         worker_host: worker_host,
         workspace_path: workspace,
         runtime: worker_runtime_name(runtime_profile),
         profile_name: worker_runtime_profile_name(runtime_profile),
         provider: worker_runtime_provider(runtime_profile),
         protocol: worker_runtime_protocol(runtime_profile),
         adapter: worker_runtime_protocol(runtime_profile),
         transport: worker_runtime_transport(runtime_profile),
         display_name: worker_runtime_display_name(runtime_profile)
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace, _opts), do: :ok

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp role_backend_start_opts(role, opts, worker_host, _role_opts, profile) do
    case Keyword.get(opts, :"#{role}_backend_module") do
      nil ->
        default_opts =
          case profile_protocol(profile) do
            "acp" ->
              opts
              |> Keyword.take([:acp_on_event])
              |> Keyword.put(:worker_host, worker_host)

            _other ->
              [worker_host: worker_host]
          end

        Keyword.merge(default_opts, Keyword.get(opts, :"#{role}_backend_opts", []))

      _module ->
        opts
        |> Keyword.get(:"#{role}_backend_opts", [])
        |> Keyword.put(:worker_host, worker_host)
    end
  end

  defp role_backend_turn_opts(role, opts, _role_opts) do
    Keyword.get(opts, :"#{role}_turn_opts", [])
  end

  defp role_runtime(role, opts, role_opts \\ []) do
    case Keyword.get(role_opts, :runtime) do
      runtime when is_binary(runtime) and runtime != "" -> runtime
      _ -> Config.agent_runtime(role, opts)
    end
  end

  defp resolve_role_profile(role, opts, role_opts) do
    case Keyword.get(opts, :runtime_profile) do
      %RuntimeProfile{} = profile ->
        if role == :worker and not Keyword.has_key?(role_opts, :runtime) do
          {:ok, profile}
        else
          resolve_profile_by_role(role, role_opts)
        end

      _other ->
        resolve_profile_by_role(role, role_opts)
    end
  end

  defp resolve_profile_by_role(role, role_opts) do
    case Keyword.get(role_opts, :runtime) do
      runtime when is_binary(runtime) and runtime != "" ->
        RuntimeRegistry.resolve_by_name(runtime)

      _ ->
        case role do
          :arbiter -> RuntimeRegistry.resolve_by_name(Config.agent_runtime(:arbiter))
          _ -> RuntimeRegistry.resolve_for_role(role)
        end
    end
  end

  defp resolve_worker_runtime_profile(opts) do
    case Keyword.get(opts, :runtime_profile) do
      %RuntimeProfile{} = profile ->
        {:ok, profile}

      _other ->
        case RuntimeRegistry.resolve_for_role(:worker) do
          {:ok, profile} -> {:ok, profile}
          {:error, _reason} -> :fallback
        end
    end
  end

  defp profile_name(%RuntimeProfile{config: config}), do: config.name
  defp profile_name(_profile), do: nil

  defp profile_provider(%RuntimeProfile{config: config}), do: config.provider
  defp profile_provider(_profile), do: nil

  defp profile_protocol(%RuntimeProfile{config: config}), do: config.adapter
  defp profile_protocol(_profile), do: nil

  defp profile_transport(%RuntimeProfile{config: %{transport: transport}}) when is_binary(transport) and transport != "",
    do: transport

  defp profile_transport(%RuntimeProfile{config: %{adapter: "acp", endpoint: endpoint}})
       when is_binary(endpoint) and endpoint != "",
       do: "http"

  defp profile_transport(%RuntimeProfile{config: %{adapter: "acp", command: command}})
       when is_binary(command) and command != "",
       do: "stdio"

  defp profile_transport(%RuntimeProfile{config: %{adapter: "direct"}}), do: "stdio"
  defp profile_transport(_profile), do: nil

  defp profile_display_name(%RuntimeProfile{config: config}), do: config.display_name
  defp profile_display_name(_profile), do: nil

  defp profile_runtime_name(%RuntimeProfile{config: config}) do
    config.name || config.provider || "codex"
  end

  defp profile_runtime_name(_profile), do: "codex"

  defp worker_runtime_name({:ok, profile}), do: profile_runtime_name(profile)
  defp worker_runtime_name(:fallback), do: "codex"

  defp worker_runtime_profile_name({:ok, profile}), do: profile_name(profile)
  defp worker_runtime_profile_name(:fallback), do: "codex"

  defp worker_runtime_provider({:ok, profile}), do: profile_provider(profile)
  defp worker_runtime_provider(:fallback), do: "codex"

  defp worker_runtime_protocol({:ok, profile}), do: profile_protocol(profile)
  defp worker_runtime_protocol(:fallback), do: "direct"

  defp worker_runtime_transport({:ok, profile}), do: profile_transport(profile)
  defp worker_runtime_transport(:fallback), do: "stdio"

  defp worker_runtime_display_name({:ok, profile}), do: profile_display_name(profile)
  defp worker_runtime_display_name(:fallback), do: nil

  defp maybe_put_role_runtime_value(map, _key, nil), do: map
  defp maybe_put_role_runtime_value(map, key, value), do: Map.put(map, key, value)

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp normalize_plan_judge_summary(summary) when is_binary(summary) do
    summary
    |> String.replace("Arbiter", "Plan judge")
    |> String.replace("arbiter", "plan judge")
  end

  defp normalize_plan_judge_summary(summary), do: summary
end
