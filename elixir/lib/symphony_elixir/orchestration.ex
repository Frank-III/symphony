defmodule SymphonyElixir.Orchestration do
  @moduledoc """
  Artifact management and phase-aware prompt assembly for
  brainstorm → arbiter → worker → judge orchestration.
  """

  alias SymphonyElixir.Config

  @phases [:brainstorm, :arbiter, :worker, :judge]

  @type phase :: :brainstorm | :arbiter | :worker | :judge

  @spec phases() :: [phase()]
  def phases, do: @phases

  # --- Artifact paths ---

  @spec proposals_dir(Path.t()) :: Path.t()
  def proposals_dir(workspace) do
    Path.join([workspace, artifact_dir(), "proposals"])
  end

  @spec proposal_path(Path.t(), pos_integer()) :: Path.t()
  def proposal_path(workspace, index) when is_integer(index) and index >= 1 do
    Path.join(proposals_dir(workspace), "planner-#{index}.json")
  end

  @spec plan_path(Path.t()) :: Path.t()
  def plan_path(workspace) do
    Path.join([workspace, artifact_dir(), "plan.json"])
  end

  @spec judge_path(Path.t()) :: Path.t()
  def judge_path(workspace) do
    Path.join([workspace, artifact_dir(), "judge.json"])
  end

  @spec ensure_artifact_dirs!(Path.t()) :: :ok
  def ensure_artifact_dirs!(workspace) do
    File.mkdir_p!(proposals_dir(workspace))
    :ok
  end

  # --- Artifact validation ---

  @proposal_required_keys ~w(summary tasks)
  @plan_required_keys ~w(version cycle tasks next_task_id selected_proposals)
  @judge_required_keys ~w(decision)
  @judge_linear_key "linear_tool_usage"

  @spec validate_proposal(Path.t()) :: {:ok, map()} | {:error, term()}
  def validate_proposal(path) do
    with {:ok, decoded} <- read_json_artifact(path),
         :ok <- require_keys(decoded, @proposal_required_keys, {:invalid_proposal, path}) do
      {:ok, decoded}
    end
  end

  @spec validate_plan(Path.t()) :: {:ok, map()} | {:error, term()}
  def validate_plan(path) do
    with {:ok, decoded} <- read_json_artifact(path),
         :ok <- require_keys(decoded, @plan_required_keys, {:invalid_plan, path}) do
      {:ok, decoded}
    end
  end

  @spec validate_judge(Path.t()) :: {:ok, map()} | {:error, term()}
  def validate_judge(path) do
    with {:ok, decoded} <- read_json_artifact(path),
         :ok <- require_keys(decoded, @judge_required_keys, {:invalid_judge, path}) do
      {:ok, decoded}
    end
  end

  @spec validate_judge_linear_evidence(map()) :: :ok | {:error, :missing_linear_evidence}
  def validate_judge_linear_evidence(judge) do
    case Map.get(judge, @judge_linear_key, []) do
      evidence when is_list(evidence) and length(evidence) > 0 -> :ok
      _ -> {:error, :missing_linear_evidence}
    end
  end

  defp read_json_artifact(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(content) do
      {:ok, decoded}
    else
      {:ok, _not_map} -> {:error, {:artifact_not_object, path}}
      {:error, reason} -> {:error, {:artifact_read_failed, path, reason}}
    end
  end

  defp require_keys(map, keys, error_prefix) do
    missing = Enum.reject(keys, &Map.has_key?(map, &1))

    if missing == [] do
      :ok
    else
      {:error, Tuple.insert_at(error_prefix, tuple_size(error_prefix), {:missing_keys, missing})}
    end
  end

  @spec list_proposals(Path.t()) :: [Path.t()]
  def list_proposals(workspace) do
    dir = proposals_dir(workspace)

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "planner-"))
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.sort()
      |> Enum.map(&Path.join(dir, &1))
    else
      []
    end
  end

  # --- Phase-aware prompts ---

  @spec phase_prompt(phase(), map()) :: String.t()
  def phase_prompt(:brainstorm, %{issue: issue, planner_index: index, proposals_dir: dir}) do
    """
    You are brainstorm planner #{index} for issue #{issue.identifier}.

    Issue: #{issue.title}
    Description:
    #{issue.description || "No description provided."}

    Instructions:
    - Analyze the issue and produce an independent implementation proposal.
    - Write your proposal as JSON to: #{dir}/planner-#{index}.json
    - The JSON must include: "version", "cycle", "planner_index", "summary", "rationale", and "tasks" (array of {id, title, status, instructions}).
    - Do not coordinate with other planners. Produce your own independent analysis.
    - Keep planner phase read-only with respect to Linear workpad/comment flows.
    """
  end

  def phase_prompt(:arbiter, %{issue: issue, proposal_paths: paths, plan_path: plan_path}) do
    proposal_list = Enum.map_join(paths, "\n", &("  - #{&1}"))

    """
    You are the arbiter for issue #{issue.identifier}.

    Issue: #{issue.title}

    The following planner proposals have been generated:
    #{proposal_list}

    Instructions:
    - Read all proposals and synthesize a single canonical plan.
    - The canonical plan should take the best ideas from each proposal.
    - Write the canonical plan as JSON to: #{plan_path}
    - The JSON must include: "version", "cycle", "summary", "tasks" (array of {id, title, status, instructions}), "next_task_id", and "selected_proposals" (array of planner indices used).
    - Keep arbiter phase read-only with respect to Linear workpad/comment flows.
    """
  end

  def phase_prompt(:worker, %{issue: issue, plan_path: plan_path, cycle: cycle, total_cycles: total_cycles}) do
    """
    You are the worker for cycle #{cycle} of #{total_cycles}.
    Read and execute the canonical plan at #{plan_path}.
    Focus on the selected next task, keep diffs scoped, and run verification when possible.
    Do not restart planning unless the repository state proves the canonical plan is invalid.

    Issue: #{issue.identifier} - #{issue.title}
    """
  end

  def phase_prompt(:judge, %{issue: issue, plan_path: plan_path, judge_path: judge_path}) do
    """
    You are the judge for issue #{issue.identifier}.

    Issue: #{issue.title}

    Instructions:
    - Review the work done by the worker against the canonical plan at #{plan_path}.
    - Use the linear_graphql tool to verify the current issue state in Linear.
    - Assess whether acceptance criteria are met.
    - Write your final decision as JSON to: #{judge_path}
    - The JSON must include: "decision" (accept | reject | replan), "rationale", "linear_tool_usage" (array of queries executed), and optionally "replan_guidance".
    - You MUST use the linear_graphql tool at least once to verify issue state before writing your decision.
    """
  end

  @phase_default_runtimes %{
    brainstorm: "codex",
    arbiter: "codex",
    worker: "claude",
    judge: "claude"
  }

  @spec runtime_for_phase(phase()) :: String.t()
  def runtime_for_phase(phase) when phase in @phases do
    settings = Config.settings!().orchestration
    role_key = to_string(phase)

    case settings.role_overrides do
      %{} = overrides when map_size(overrides) > 0 ->
        case Map.get(overrides, role_key) do
          %{"runtime" => runtime} when is_binary(runtime) -> runtime
          _ -> phase_default(phase, settings.primary_agent_runtime)
        end

      _ ->
        phase_default(phase, settings.primary_agent_runtime)
    end
  end

  # Worker and judge use the configured primary_agent_runtime;
  # brainstorm and arbiter keep their static defaults.
  defp phase_default(:worker, primary_runtime), do: primary_runtime
  defp phase_default(:judge, primary_runtime), do: primary_runtime
  defp phase_default(phase, _primary_runtime), do: Map.fetch!(@phase_default_runtimes, phase)

  defp artifact_dir do
    Config.orchestration_artifact_dir()
  end
end
