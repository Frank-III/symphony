defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, OrchestrationFiles, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    role = normalize_role(Keyword.get(opts, :role, :worker))
    cycle = Keyword.get(opts, :cycle)
    max_cycles = Keyword.get(opts, :max_cycles)
    orchestration_mode = Keyword.get(opts, :orchestration_mode) || safe_orchestration_mode()
    planner_index = Keyword.get(opts, :planner_index)
    planner_count = Keyword.get(opts, :planner_count)

    artifact_paths =
      OrchestrationFiles.artifact_paths(
        Keyword.get(opts, :workspace),
        planner_index: planner_index,
        planner_count: planner_count
      )

    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    rendered_prompt =
      template
      |> Solid.render!(
        %{
          "agent" => %{
            "cycle" => cycle,
            "max_cycles" => max_cycles,
            "orchestration_mode" => orchestration_mode,
            "planner_count" => planner_count,
            "planner_index" => planner_index,
            "role" => role,
            "runtime" => Keyword.get(opts, :runtime) || safe_runtime_for_role(role)
          },
          "attempt" => Keyword.get(opts, :attempt),
          "artifacts" => artifact_paths,
          "issue" => issue |> Map.from_struct() |> to_solid_map()
        },
        @render_opts
      )
      |> IO.iodata_to_binary()
      |> role_scoped_prompt(orchestration_mode, role)

    [
      role_execution_preamble(orchestration_mode, role),
      rendered_prompt,
      append_orchestration_guidance(
        "",
        orchestration_mode,
        role,
        artifact_paths,
        cycle,
        max_cycles
      ),
      retry_guidance(
        role,
        Keyword.get(opts, :attempt),
        Keyword.get(opts, :retry_reason),
        artifact_paths
      )
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp normalize_role(role) when role in [:planner, :arbiter, :worker, :judge],
    do: Atom.to_string(role)

  defp normalize_role(role)
       when is_binary(role) and role in ["planner", "arbiter", "worker", "judge"],
       do: role

  defp normalize_role(_role), do: "worker"

  defp append_orchestration_guidance(
         prompt,
         "planner_worker_judge",
         role,
         %{"plan_path" => plan_path, "judge_path" => judge_path},
         cycle,
         max_cycles
       )
       when is_binary(plan_path) and is_binary(judge_path) do
    prompt <> "\n\n" <> orchestration_guidance(role, plan_path, judge_path, cycle, max_cycles)
  end

  defp append_orchestration_guidance(
         prompt,
         "brainstorm_arbiter_worker_judge",
         role,
         artifact_paths,
         cycle,
         max_cycles
       ) do
    prompt <>
      "\n\n" <>
      orchestration_guidance(
        "brainstorm_arbiter_worker_judge",
        role,
        artifact_paths,
        cycle,
        max_cycles
      )
  end

  defp append_orchestration_guidance(prompt, _mode, _role, _artifact_paths, _cycle, _max_cycles),
    do: prompt

  defp role_scoped_prompt(prompt, orchestration_mode, role)
       when orchestration_mode in ["planner_worker_judge", "brainstorm_arbiter_worker_judge"] and
              role in ["planner", "arbiter"] do
    prompt
    |> split_before_heading("## Default posture")
    |> split_before_heading("## Step 0: Determine current ticket state and route")
    |> String.trim_trailing()
  end

  defp role_scoped_prompt(prompt, _orchestration_mode, _role), do: prompt

  defp split_before_heading(prompt, heading) when is_binary(prompt) and is_binary(heading) do
    case String.split(prompt, heading, parts: 2) do
      [prefix, _rest] -> String.trim_trailing(prefix)
      _ -> prompt
    end
  end

  defp role_execution_preamble("planner_worker_judge", "planner") do
    """
    Planner execution contract:

    - Treat this role as read-only planning. Do not modify Linear issue state, comments, PRs, branches, or tracker metadata.
    - Do not create or edit the `## Codex Workpad`.
    - Inspect the repository and any existing tracker/workpad state only to inform the plan.
    - Ignore generic execution workflow instructions about workpads, issue transitions, PRs, validation, pull/push, or landing; those apply to worker and judge phases, not this planner turn.
    - Your only required side effect is writing the planner artifact file for this cycle.
    """
  end

  defp role_execution_preamble("brainstorm_arbiter_worker_judge", "planner") do
    """
    Brainstorm planner execution contract:

    - Treat this role as read-only planning. Do not modify Linear issue state, comments, PRs, branches, or tracker metadata.
    - Do not create or edit the `## Codex Workpad`.
    - Avoid GitHub/Linear write operations entirely unless the orchestrator explicitly asks for them in a later worker or judge phase.
    - Use tracker data only for read-only context gathering.
    - Ignore generic execution workflow instructions about workpads, issue transitions, PRs, validation, pull/push, or landing; those apply to worker and judge phases, not this planner turn.
    - Your only required side effect is writing your brainstorm proposal JSON for this cycle.
    """
  end

  defp role_execution_preamble("brainstorm_arbiter_worker_judge", "arbiter") do
    """
    Plan judge execution contract:

    - Treat this role as read-only synthesis. Do not modify Linear issue state, comments, PRs, branches, or tracker metadata.
    - Do not create or edit the `## Codex Workpad`.
    - Ignore generic execution workflow instructions about workpads, issue transitions, PRs, validation, pull/push, or landing; those apply to worker and execution-judge phases, not this plan-judge turn.
    - Read proposal artifacts, choose the best direction, and write the canonical plan artifact only.
    """
  end

  defp role_execution_preamble(_orchestration_mode, _role), do: ""

  defp orchestration_guidance("planner", plan_path, _judge_path, cycle, max_cycles) do
    """
    Planner role guidance:

    - You are the planner for cycle #{cycle_label(cycle)}#{max_cycles_label(max_cycles)}.
    - Explore the current codebase and workspace state before proposing work.
    - Write a fresh JSON plan to `#{plan_path}` before ending your turn.
    - The plan JSON must look like:
      {"version":1,"cycle":#{integer_or_null(cycle)},"summary":"...","tasks":[{"id":"T1","title":"...","status":"pending","instructions":"..."}],"next_task_id":"T1"}
    - Keep tasks concrete, small, and directly executable by a worker.
    - Refresh the plan to match the current repository state instead of appending stale tasks.
    """
  end

  defp orchestration_guidance("worker", plan_path, _judge_path, cycle, max_cycles) do
    """
    Worker role guidance:

    - You are the worker for cycle #{cycle_label(cycle)}#{max_cycles_label(max_cycles)}.
    - Read and follow the current plan at `#{plan_path}`.
    - Execute the highest-leverage pending task, keep diffs scoped, and run verification when possible.
    - If the plan is stale, update it only when the codebase proves the task list is wrong.
    - Focus on shipping progress, not on re-planning the whole issue.
    """
  end

  defp orchestration_guidance("judge", _plan_path, judge_path, cycle, max_cycles) do
    """
    Judge role guidance:

    - You are the judge for cycle #{cycle_label(cycle)}#{max_cycles_label(max_cycles)}.
    - Inspect the repository, current workspace state, and prior plan before deciding what happens next.
    - Write a fresh JSON decision to `#{judge_path}` before ending your turn.
    - The decision JSON must look like:
      {"version":1,"cycle":#{integer_or_null(cycle)},"decision":"continue|done|blocked","summary":"...","next_focus":"..."}
    - Use `continue` when another planner/worker cycle should run, `done` when the issue objective is satisfied, and `blocked` when outside action is required.
    - If you choose `done` or `blocked` while the tracker still marks the issue as active, update the issue state before ending.
    - Do not finish your turn until the decision file exists and reflects your final judgement.
    """
  end

  defp orchestration_guidance(
         "brainstorm_arbiter_worker_judge",
         "planner",
         %{
           "artifact_writer_path" => artifact_writer_path,
           "current_proposal_path" => current_proposal_path,
           "proposal_paths" => proposal_paths
         },
         cycle,
         max_cycles
       )
       when is_binary(artifact_writer_path) and is_binary(current_proposal_path) and is_list(proposal_paths) do
    """
    Brainstorm planner guidance:

    - You are one brainstorm planner for cycle #{cycle_label(cycle)}#{max_cycles_label(max_cycles)}.
    - Explore the current codebase independently and do not wait for the other planners.
    - Your first action must be overwriting `#{current_proposal_path}` with a concrete JSON draft immediately.
    - Do not read any repo files before that first write. Use the issue description and the JSON schema below to draft a best-effort proposal.
    - Before any deeper analysis, create a minimal valid JSON draft at `#{current_proposal_path}` and keep refining that same file until it is your final answer.
    - Use the artifact writer helper for every proposal update: `cat <<'JSON' | #{artifact_writer_path} #{current_proposal_path}` then paste the full JSON and close with `JSON`.
    - Prefer `Write`/`Edit` for the proposal file itself.
    - If you do not update the file directly, your final response must be exactly one JSON object matching the proposal schema and nothing else. Symphony will persist that JSON for you.
    - Do not use `Glob` or `Grep` before the file already contains a concrete `summary`, `rationale`, and at least one fully specified task.
    - If you still need code context after the draft is concrete, read at most 2 exact file paths and then finalize the proposal immediately.
    - Do not spawn sub-agents, do not delegate planning, and do not use broad shell exploration for this planner role.
    - Planning should stay cheap. Prefer the issue description plus a handful of targeted reads over broad repository exploration.
    - Do not run broad scans across the whole repo. Read at most 8 files unless the issue cannot be planned without one extra targeted read.
    - Write your proposal JSON to `#{current_proposal_path}` before ending your turn.
    - The brainstorm proposal JSON must look like:
      {"version":1,"cycle":#{integer_or_null(cycle)},"planner_index":{{ agent.planner_index | default: null }},"summary":"...","rationale":"...","tasks":[{"id":"T1","title":"...","status":"pending","instructions":"..."}]}
    - The full proposal set for this cycle lives at: #{Enum.join(proposal_paths, ", ")}.
    - Focus on generating a strong plan alternative rather than implementing code.
    - A proposal is not finished until `summary`, `rationale`, and at least one task `id`, `title`, and `instructions` are all concrete and no longer placeholders like `"..."`.
    - As soon as that file contains your final JSON proposal, stop. Do not continue analyzing, narrating, or editing anything else in the session.
    - If the file already contains the final JSON, your final response should be empty or one very short confirmation sentence only.
    """
  end

  defp orchestration_guidance(
         "brainstorm_arbiter_worker_judge",
         "arbiter",
         %{
           "artifact_writer_path" => artifact_writer_path,
           "proposal_paths" => proposal_paths,
           "plan_path" => plan_path
         },
         cycle,
         max_cycles
       )
       when is_binary(artifact_writer_path) and is_list(proposal_paths) and is_binary(plan_path) do
    """
    Plan judge role guidance:

    - You are the planning judge for cycle #{cycle_label(cycle)}#{max_cycles_label(max_cycles)}.
    - Read all brainstorm proposals before deciding on the canonical direction.
    - The brainstorm proposals are expected at: #{Enum.join(proposal_paths, ", ")}.
    - Your first action must be opening `#{plan_path}`, replacing the placeholder fields, and writing back a concrete JSON draft immediately.
    - Before that first write, the only files you may read are `#{plan_path}` and the brainstorm proposal files.
    - Before any deeper synthesis, create a minimal valid JSON draft at `#{plan_path}` and keep refining that same file until it is your final answer.
    - Use the artifact writer helper for every plan update: `cat <<'JSON' | #{artifact_writer_path} #{plan_path}` then paste the full JSON and close with `JSON`.
    - Prefer `Read` for proposal/repo inspection and `Write`/`Edit` for the plan file itself.
    - If you do not update the file directly, your final response must be exactly one JSON object matching the plan schema and nothing else. Symphony will persist that JSON for you.
    - Do not use `Glob` or `Grep` before `#{plan_path}` already contains a concrete `summary`, `next_task_id`, and at least one fully specified task.
    - If the proposals disagree and you need repo context, read at most 2 exact file paths and then finalize the plan immediately.
    - Do not spawn sub-agents, do not delegate synthesis, and do not use broad shell exploration for this plan-judge role.
    - Plan judging should stay cheap. Synthesize from the proposal files first and only inspect repo files if the proposals clearly disagree about a technical constraint.
    - Write the canonical plan JSON to `#{plan_path}` before ending your turn.
    - The plan JSON must look like:
      {"version":1,"cycle":#{integer_or_null(cycle)},"summary":"...","tasks":[{"id":"T1","title":"...","status":"pending","instructions":"..."}],"next_task_id":"T1","selected_proposals":[1]}
    - Synthesize the best task list for the worker. Do not implement code yourself.
    - The plan is not finished until `summary`, `next_task_id`, and at least one task `id`, `title`, and `instructions` are all concrete and no longer placeholders like `"..."`.
    - As soon as that file contains your final JSON plan, stop. Do not continue analyzing, narrating, or editing anything else in the session.
    - If the file already contains the final JSON, your final response should be empty or one very short confirmation sentence only.
    """
  end

  defp orchestration_guidance(
         "brainstorm_arbiter_worker_judge",
         "worker",
         %{"plan_path" => plan_path},
         cycle,
         max_cycles
       )
       when is_binary(plan_path) do
    """
    Worker role guidance:

    - You are the worker for cycle #{cycle_label(cycle)}#{max_cycles_label(max_cycles)}.
    - Read and execute the canonical plan at `#{plan_path}`.
    - Focus on the selected next task, keep diffs scoped, and run verification when possible.
    - Do not restart planning unless the repository state proves the canonical plan is invalid.
    """
  end

  defp orchestration_guidance(
         "brainstorm_arbiter_worker_judge",
         "judge",
         %{"plan_path" => plan_path, "judge_path" => judge_path},
         cycle,
         max_cycles
       )
       when is_binary(plan_path) and is_binary(judge_path) do
    """
    Judge role guidance:

    - You are the final judge for cycle #{cycle_label(cycle)}#{max_cycles_label(max_cycles)}.
    - Inspect the repository, the canonical plan at `#{plan_path}`, and the current workspace state.
    - Write a fresh JSON decision to `#{judge_path}` before ending your turn.
    - The decision JSON must look like:
      {"version":1,"cycle":#{integer_or_null(cycle)},"decision":"continue|done|blocked","summary":"...","next_focus":"..."}
    - Use `continue` when another brainstorm/arbiter/worker/judge cycle should run, `done` when the issue objective is satisfied, and `blocked` when outside action is required.
    - If you choose `done` or `blocked` while the tracker still marks the issue as active, update the issue state before ending.
    """
  end

  defp orchestration_guidance(
         "brainstorm_arbiter_worker_judge",
         _role,
         _artifact_paths,
         _cycle,
         _max_cycles
       ),
       do: ""

  defp cycle_label(cycle) when is_integer(cycle) and cycle > 0, do: Integer.to_string(cycle)
  defp cycle_label(_cycle), do: "unknown"

  defp max_cycles_label(max_cycles) when is_integer(max_cycles) and max_cycles > 0,
    do: " of #{max_cycles}"

  defp max_cycles_label(_max_cycles), do: ""

  defp integer_or_null(value) when is_integer(value), do: Integer.to_string(value)
  defp integer_or_null(_value), do: "null"

  defp safe_orchestration_mode do
    Config.agent_orchestration_mode()
  rescue
    ArgumentError -> "single"
  end

  defp safe_runtime_for_role(role) do
    role
    |> String.to_atom()
    |> Config.agent_runtime()
  rescue
    ArgumentError -> "codex"
  end

  defp retry_guidance(role, attempt, retry_reason, artifact_paths)
       when role in ["planner", "arbiter"] and is_integer(attempt) and attempt > 1 do
    artifact_path =
      case role do
        "planner" -> Map.get(artifact_paths, "current_proposal_path")
        "arbiter" -> Map.get(artifact_paths, "plan_path")
      end

    """
    Retry guidance:

    - The previous #{role_label(role)} attempt ended before replacing the placeholder artifact.
    - Previous failure: #{format_retry_reason(retry_reason)}.
    - On this retry, overwrite `#{artifact_path}` before reading any repo file other than the artifact itself.
    - If you use `Glob` or `Grep`, or read another repo file before that first overwrite, the orchestrator will stop the turn immediately.
    """
  end

  defp retry_guidance(_role, _attempt, _retry_reason, _artifact_paths), do: ""

  defp role_label("planner"), do: "planner"
  defp role_label("arbiter"), do: "plan-judge"
  defp role_label(role), do: role

  defp format_retry_reason({:artifact_write_first_violation, artifact_path, tool_name, _event})
       when is_binary(artifact_path) do
    "attempted #{inspect(tool_name)} before overwriting #{artifact_path}"
  end

  defp format_retry_reason({:artifact_watchdog_triggered, artifact_path, _count, _budget, event})
       when is_binary(artifact_path) do
    "hit the artifact watchdog on #{artifact_path} after #{inspect(event)} activity"
  end

  defp format_retry_reason({:artifact_incomplete_after_turn, artifact_path, reason})
       when is_binary(artifact_path) do
    "finished without producing a valid artifact at #{artifact_path}: #{inspect(reason)}"
  end

  defp format_retry_reason(reason) when is_binary(reason), do: reason
  defp format_retry_reason(reason) when not is_nil(reason), do: inspect(reason)
  defp format_retry_reason(_reason), do: "artifact remained placeholder"
end
