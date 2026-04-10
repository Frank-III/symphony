defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @type agent_role :: :planner | :arbiter | :worker | :judge
  @type agent_runtime :: String.t()

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec agent_orchestration_mode() :: String.t()
  def agent_orchestration_mode do
    settings!().agent.orchestration_mode
  end

  @spec agent_plan_review_required?() :: boolean()
  def agent_plan_review_required? do
    settings!().agent.plan_review_required
  end

  @spec agent_runtime(agent_role(), keyword()) :: agent_runtime()
  def agent_runtime(role \\ :worker, opts \\ []) do
    case Keyword.get(opts, :runtime) do
      runtime when is_binary(runtime) and runtime != "" ->
        runtime

      _ ->
        settings = settings!()
        default_runtime = Schema.materialize_codex_default_profile(settings).name

        case role do
          :planner ->
            settings.planner_runtime ||
              List.first(Schema.resolve_planner_runtimes(settings)) ||
              default_runtime

          :arbiter ->
            settings.planner_runtime ||
              List.first(Schema.resolve_planner_runtimes(settings)) ||
              settings.judge_runtime ||
              settings.worker_runtime ||
              List.first(Schema.resolve_worker_runtimes(settings)) ||
              default_runtime

          :judge ->
            settings.judge_runtime ||
              settings.worker_runtime ||
              List.first(Schema.resolve_worker_runtimes(settings)) ||
              default_runtime

          :worker ->
            settings.worker_runtime || List.first(Schema.resolve_worker_runtimes(settings)) || default_runtime
        end
    end
  end

  @spec runtime_pool() :: [agent_runtime()]
  def runtime_pool, do: runtime_pool(:worker, [])

  @spec runtime_pool(agent_role()) :: [agent_runtime()]
  def runtime_pool(role), do: runtime_pool(role, [])

  @spec runtime_pool(agent_role(), keyword()) :: [agent_runtime()]
  def runtime_pool(:worker, opts) do
    case Keyword.get(opts, :runtime) do
      runtime when is_binary(runtime) and runtime != "" ->
        [runtime]

      _ ->
        settings = settings!()
        default_runtime = Schema.materialize_codex_default_profile(settings).name

        [settings.worker_runtime | Schema.resolve_worker_runtimes(settings)]
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.uniq()
        |> case do
          [] -> [default_runtime]
          pool -> pool
        end
    end
  end

  def runtime_pool(role, opts), do: [agent_runtime(role, opts)]

  @spec brainstorm_planner_runtimes() :: [agent_runtime()]
  def brainstorm_planner_runtimes do
    settings = settings!()
    planner_runtimes = Schema.resolve_planner_runtimes(settings)

    if planner_runtimes == [] do
      List.duplicate(agent_runtime(:planner), settings.agent.brainstorm_planners)
    else
      planner_runtimes
    end
  end

  @spec runtime_session_requirements() :: %{agent_runtime() => pos_integer()}
  def runtime_session_requirements do
    case agent_orchestration_mode() do
      "planner_worker_judge" ->
        [agent_runtime(:planner)]
        |> Kernel.++(runtime_pool(:worker))
        |> Kernel.++([agent_runtime(:judge)])
        |> count_runtimes()

      "brainstorm_arbiter_worker_judge" ->
        brainstorm_planner_runtimes()
        |> Kernel.++([agent_runtime(:arbiter)])
        |> Kernel.++(runtime_pool(:worker))
        |> Kernel.++([agent_runtime(:judge)])
        |> count_runtimes()

      _other ->
        runtime_pool(:worker)
        |> count_runtimes()
    end
  end

  @spec configured_runtimes() :: [agent_runtime()]
  def configured_runtimes do
    runtime_session_requirements()
    |> Map.keys()
    |> Enum.sort()
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  @spec runtime_profile_for_role(atom()) ::
          {:ok, Schema.RuntimeProfile.t()} | {:error, term()}
  def runtime_profile_for_role(role) when role in [:planner, :arbiter, :worker, :judge] do
    with {:ok, settings} <- settings() do
      default_profile = Schema.materialize_codex_default_profile(settings)

      case agent_runtime(role) do
        nil ->
          {:ok, default_profile}

        name when map_size(settings.runtimes) == 0 and name == default_profile.name ->
          {:ok, default_profile}

        name ->
          case Schema.runtime_profile(settings, name) do
            {:ok, profile} -> {:ok, profile}
            {:error, :not_found} when name == default_profile.name -> {:ok, default_profile}
            {:error, :not_found} -> {:error, {:undefined_runtime, name}}
          end
      end
    end
  end

  @spec runtime_profiles() :: {:ok, %{String.t() => Schema.RuntimeProfile.t()}} | {:error, term()}
  def runtime_profiles do
    with {:ok, settings} <- settings() do
      profiles = settings.runtimes

      if map_size(profiles) == 0 do
        {:ok, %{"codex" => Schema.materialize_codex_default_profile(settings)}}
      else
        {:ok, profiles}
      end
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp count_runtimes(runtimes) when is_list(runtimes) do
    Enum.reduce(runtimes, %{}, fn runtime, counts ->
      Map.update(counts, runtime, 1, &(&1 + 1))
    end)
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
