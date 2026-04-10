defmodule SymphonyElixir.OrchestrationFiles do
  @moduledoc false

  @version 1
  @orchestration_dir ".symphony/orchestration"
  @proposal_dirname "proposals"
  @plan_filename "plan.json"
  @judge_filename "judge.json"
  @plan_review_filename "plan_review.json"

  @type judge_decision :: :continue | :done | :blocked
  @type judge_result :: %{
          decision: judge_decision(),
          summary: String.t() | nil,
          next_focus: String.t() | nil,
          raw: map()
        }

  @type plan_result :: %{
          summary: String.t() | nil,
          next_task_id: String.t() | nil,
          task_count: non_neg_integer(),
          raw: map()
        }

  @spec write_proposal(Path.t(), pos_integer(), map()) :: :ok | {:error, term()}
  def write_proposal(workspace, planner_index, %{} = payload)
      when is_binary(workspace) and is_integer(planner_index) and planner_index > 0 do
    with {:ok, normalized_payload} <-
           normalize_proposal_payload(payload, planner_index: planner_index) do
      write_json_file(proposal_path(workspace, planner_index), normalized_payload)
    end
  end

  @spec write_plan(Path.t(), map()) :: :ok | {:error, term()}
  def write_plan(workspace, %{} = payload) when is_binary(workspace) do
    with {:ok, normalized_payload} <- normalize_plan_payload(payload) do
      write_json_file(plan_path(workspace), normalized_payload)
    end
  end

  @spec materialize_artifact(Path.t(), term()) :: :ok | {:error, term()}
  def materialize_artifact(artifact_path, candidate) when is_binary(artifact_path) do
    materialize_artifact(artifact_path, candidate, [])
  end

  @spec materialize_artifact(Path.t(), term(), keyword()) :: :ok | {:error, term()}
  def materialize_artifact(artifact_path, candidate, opts) when is_binary(artifact_path) do
    with {:ok, %{} = payload} <- decode_json_object(candidate),
         {:ok, normalized_payload} <- normalize_artifact_payload(artifact_path, payload, opts) do
      write_json_file(artifact_path, normalized_payload)
    end
  end

  @spec seed_proposal_draft(Path.t(), pos_integer(), integer() | nil) :: :ok | {:error, term()}
  def seed_proposal_draft(workspace, planner_index, cycle)
      when is_binary(workspace) and is_integer(planner_index) and planner_index > 0 do
    payload = %{
      "version" => @version,
      "cycle" => cycle,
      "planner_index" => planner_index,
      "summary" => "...",
      "rationale" => "...",
      "tasks" => [
        %{
          "id" => "T#{planner_index}",
          "title" => "...",
          "status" => "pending",
          "instructions" => "..."
        }
      ]
    }

    write_json_file(proposal_path(workspace, planner_index), payload)
  end

  @spec seed_plan_draft(Path.t(), integer() | nil) :: :ok | {:error, term()}
  def seed_plan_draft(workspace, cycle) when is_binary(workspace) do
    payload = %{
      "version" => @version,
      "cycle" => cycle,
      "summary" => "...",
      "tasks" => [
        %{
          "id" => "T1",
          "title" => "...",
          "status" => "pending",
          "instructions" => "..."
        }
      ],
      "next_task_id" => "T1",
      "selected_proposals" => []
    }

    write_json_file(plan_path(workspace), payload)
  end

  @spec prepare(Path.t()) :: :ok | {:error, term()}
  def prepare(workspace) when is_binary(workspace) do
    with :ok <- File.mkdir_p(orchestration_dir(workspace)),
         :ok <- File.mkdir_p(proposal_dir(workspace)) do
      :ok
    end
  end

  @spec artifact_paths(Path.t() | nil) :: map()
  def artifact_paths(workspace), do: artifact_paths(workspace, [])

  @spec artifact_paths(Path.t() | nil, keyword()) :: map()
  def artifact_paths(workspace, opts) when is_binary(workspace) do
    planner_count = Keyword.get(opts, :planner_count)
    planner_index = Keyword.get(opts, :planner_index)

    %{
      "orchestration_dir" => orchestration_dir(workspace),
      "proposal_dir" => proposal_dir(workspace),
      "proposal_paths" => proposal_paths_for_artifacts(workspace, planner_count),
      "current_proposal_path" => proposal_path_for_artifacts(workspace, planner_index),
      "artifact_writer_path" => artifact_writer_path(workspace),
      "plan_path" => plan_path(workspace),
      "judge_path" => judge_path(workspace),
      "plan_review_path" => plan_review_path(workspace)
    }
  end

  def artifact_paths(_workspace, _opts) do
    %{
      "orchestration_dir" => nil,
      "proposal_dir" => nil,
      "proposal_paths" => [],
      "current_proposal_path" => nil,
      "artifact_writer_path" => nil,
      "plan_path" => nil,
      "judge_path" => nil,
      "plan_review_path" => nil
    }
  end

  @spec orchestration_dir(Path.t()) :: Path.t()
  def orchestration_dir(workspace) when is_binary(workspace) do
    Path.join(workspace, @orchestration_dir)
  end

  @spec proposal_dir(Path.t()) :: Path.t()
  def proposal_dir(workspace) when is_binary(workspace) do
    Path.join(orchestration_dir(workspace), @proposal_dirname)
  end

  @spec proposal_path(Path.t(), pos_integer()) :: Path.t()
  def proposal_path(workspace, planner_index)
      when is_binary(workspace) and is_integer(planner_index) and planner_index > 0 do
    Path.join(proposal_dir(workspace), "planner-#{planner_index}.json")
  end

  @spec proposal_paths(Path.t(), pos_integer()) :: [Path.t()]
  def proposal_paths(workspace, planner_count)
      when is_binary(workspace) and is_integer(planner_count) and planner_count > 0 do
    Enum.map(1..planner_count, &proposal_path(workspace, &1))
  end

  @spec plan_path(Path.t()) :: Path.t()
  def plan_path(workspace) when is_binary(workspace) do
    Path.join(orchestration_dir(workspace), @plan_filename)
  end

  @artifact_writer_relative_path "../../bin/symphony-write-artifact"

  @spec artifact_writer_path(Path.t()) :: Path.t()
  def artifact_writer_path(_workspace) do
    Path.expand(@artifact_writer_relative_path, __DIR__)
  end

  @spec judge_path(Path.t()) :: Path.t()
  def judge_path(workspace) when is_binary(workspace) do
    Path.join(orchestration_dir(workspace), @judge_filename)
  end

  @spec plan_review_path(Path.t()) :: Path.t()
  def plan_review_path(workspace) when is_binary(workspace) do
    Path.join(orchestration_dir(workspace), @plan_review_filename)
  end

  @spec clear_judge_result(Path.t()) :: :ok | {:error, term()}
  def clear_judge_result(workspace) when is_binary(workspace) do
    case File.rm(judge_path(workspace)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec clear_plan(Path.t()) :: :ok | {:error, term()}
  def clear_plan(workspace) when is_binary(workspace) do
    case File.rm(plan_path(workspace)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec clear_plan_review(Path.t()) :: :ok | {:error, term()}
  def clear_plan_review(workspace) when is_binary(workspace) do
    case File.rm(plan_review_path(workspace)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec clear_proposals(Path.t()) :: :ok | {:error, term()}
  def clear_proposals(workspace) when is_binary(workspace) do
    workspace
    |> proposal_dir()
    |> Path.join("planner-*.json")
    |> Path.wildcard()
    |> Enum.reduce_while(:ok, fn proposal_path, :ok ->
      case File.rm(proposal_path) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec load_plan(Path.t()) :: {:ok, plan_result()} | {:error, term()}
  def load_plan(workspace) when is_binary(workspace) do
    workspace
    |> plan_path()
    |> File.read()
    |> case do
      {:ok, contents} -> parse_plan(contents)
      {:error, :enoent} -> {:error, :plan_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec artifact_ready?(Path.t()) :: boolean()
  def artifact_ready?(artifact_path) when is_binary(artifact_path) do
    basename = Path.basename(artifact_path)

    cond do
      basename == @plan_filename -> valid_plan_file?(artifact_path)
      basename == @judge_filename -> valid_judge_file?(artifact_path)
      String.starts_with?(basename, "planner-") -> valid_proposal_file?(artifact_path)
      true -> File.regular?(artifact_path)
    end
  end

  @spec load_judge_result(Path.t()) :: {:ok, judge_result()} | {:error, term()}
  def load_judge_result(workspace) when is_binary(workspace) do
    workspace
    |> judge_path()
    |> File.read()
    |> case do
      {:ok, contents} -> parse_judge_result(contents)
      {:error, :enoent} -> {:error, :judge_result_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load_plan_review(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_plan_review(workspace) when is_binary(workspace) do
    workspace
    |> plan_review_path()
    |> File.read()
    |> case do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = payload} -> {:ok, payload}
          {:ok, _other} -> {:error, :plan_review_invalid_shape}
          {:error, %Jason.DecodeError{} = error} -> {:error, {:plan_review_invalid_json, error.data}}
        end

      {:error, :enoent} ->
        {:error, :plan_review_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec write_plan_review(Path.t(), map()) :: :ok | {:error, term()}
  def write_plan_review(workspace, %{} = payload) when is_binary(workspace) do
    write_json_file(plan_review_path(workspace), payload)
  end

  defp parse_plan(contents) when is_binary(contents) do
    with {:ok, %{} = payload} <- Jason.decode(contents),
         {:ok, tasks} <- normalize_plan_tasks(payload["tasks"]) do
      {:ok,
       %{
         summary: string_or_nil(payload["summary"]),
         next_task_id: string_or_nil(payload["next_task_id"]),
         task_count: length(tasks),
         raw:
           payload
           |> Map.put_new("version", @version)
       }}
    else
      {:ok, _other} -> {:error, :plan_invalid_shape}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:plan_invalid_json, error.data}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_artifact_payload(artifact_path, %{} = payload, opts) do
    basename = Path.basename(artifact_path)

    cond do
      basename == @plan_filename ->
        normalize_plan_payload(payload, opts)

      basename == @judge_filename ->
        normalize_judge_payload(payload, opts)

      String.starts_with?(basename, "planner-") ->
        planner_index =
          Keyword.get_lazy(opts, :planner_index, fn ->
            planner_index_from_artifact_path(artifact_path)
          end)

        normalize_proposal_payload(payload, Keyword.put(opts, :planner_index, planner_index))

      true ->
        {:error, {:unsupported_artifact_path, artifact_path}}
    end
  end

  defp normalize_proposal_payload(%{} = payload, opts) do
    with {:ok, tasks} <- normalize_plan_tasks(payload["tasks"]),
         true <- meaningful_text?(payload["summary"]) || {:error, :proposal_missing_summary},
         true <- meaningful_text?(payload["rationale"]) || {:error, :proposal_missing_rationale},
         true <- meaningful_tasks?(tasks) || {:error, :proposal_invalid_tasks} do
      normalized_payload =
        payload
        |> Map.put_new("version", @version)
        |> put_if_present("cycle", Keyword.get(opts, :cycle))
        |> put_if_present("planner_index", Keyword.get(opts, :planner_index))

      {:ok, normalized_payload}
    end
  end

  defp normalize_plan_payload(%{} = payload, _opts \\ []) do
    with {:ok, tasks} <- normalize_plan_tasks(payload["tasks"]),
         true <- meaningful_text?(payload["summary"]) || {:error, :plan_missing_summary},
         true <- meaningful_tasks?(tasks) || {:error, :plan_invalid_tasks},
         true <- meaningful_identifier?(payload["next_task_id"]) || {:error, :plan_missing_next_task_id} do
      {:ok, Map.put_new(payload, "version", @version)}
    end
  end

  defp normalize_judge_payload(%{} = payload, _opts) do
    with {:ok, _decision} <- normalize_judge_decision(payload["decision"]),
         true <- meaningful_text?(payload["summary"]) || {:error, :judge_result_missing_summary} do
      {:ok, Map.put_new(payload, "version", @version)}
    end
  end

  defp decode_json_object(%{} = payload), do: {:ok, payload}

  defp decode_json_object(candidate) when is_binary(candidate) do
    candidate
    |> json_object_candidates()
    |> Enum.reduce_while({:error, :artifact_candidate_invalid_json}, fn json_candidate, _acc ->
      case Jason.decode(json_candidate) do
        {:ok, %{} = payload} -> {:halt, {:ok, payload}}
        {:ok, _other} -> {:cont, {:error, :artifact_candidate_not_object}}
        {:error, _reason} -> {:cont, {:error, :artifact_candidate_invalid_json}}
      end
    end)
  end

  defp decode_json_object(_candidate), do: {:error, :artifact_candidate_unusable}

  defp json_object_candidates(candidate) when is_binary(candidate) do
    trimmed = String.trim(candidate)

    [trimmed, extract_fenced_json_object(trimmed), extract_balanced_json_object(trimmed)]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp extract_fenced_json_object(candidate) when is_binary(candidate) do
    case Regex.run(~r/```(?:json)?\s*(\{[\s\S]*\})\s*```/i, candidate, capture: :all_but_first) do
      [json] -> String.trim(json)
      _ -> nil
    end
  end

  defp extract_balanced_json_object(candidate) when is_binary(candidate) do
    case :binary.match(candidate, "{") do
      {start_index, 1} ->
        sliced = binary_part(candidate, start_index, byte_size(candidate) - start_index)

        case find_matching_json_brace(sliced, 0, false, false, 0) do
          {:ok, end_index} -> binary_part(sliced, 0, end_index + 1)
          :error -> nil
        end

      :nomatch ->
        nil
    end
  end

  defp find_matching_json_brace(<<>>, _depth, _in_string, _escaped, _index), do: :error

  defp find_matching_json_brace(
         <<char, rest::binary>>,
         depth,
         in_string,
         escaped,
         index
       ) do
    cond do
      in_string and escaped ->
        find_matching_json_brace(rest, depth, true, false, index + 1)

      in_string and char == ?\\ ->
        find_matching_json_brace(rest, depth, true, true, index + 1)

      in_string and char == ?" ->
        find_matching_json_brace(rest, depth, false, false, index + 1)

      in_string ->
        find_matching_json_brace(rest, depth, true, false, index + 1)

      char == ?" ->
        find_matching_json_brace(rest, depth, true, false, index + 1)

      char == ?{ ->
        find_matching_json_brace(rest, depth + 1, false, false, index + 1)

      char == ?} and depth == 1 ->
        {:ok, index}

      char == ?} and depth > 1 ->
        find_matching_json_brace(rest, depth - 1, false, false, index + 1)

      true ->
        find_matching_json_brace(rest, depth, false, false, index + 1)
    end
  end

  defp planner_index_from_artifact_path(artifact_path) when is_binary(artifact_path) do
    artifact_path
    |> Path.basename()
    |> case do
      "planner-" <> suffix ->
        suffix
        |> String.trim_trailing(".json")
        |> Integer.parse()
        |> case do
          {planner_index, ""} when planner_index > 0 -> planner_index
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp put_if_present(payload, _key, nil), do: payload
  defp put_if_present(payload, key, value), do: Map.put_new(payload, key, value)

  defp parse_judge_result(contents) when is_binary(contents) do
    with {:ok, payload} <- Jason.decode(contents),
         {:ok, decision} <- normalize_judge_decision(payload["decision"]) do
      {:ok,
       %{
         decision: decision,
         summary: string_or_nil(payload["summary"]),
         next_focus: string_or_nil(payload["next_focus"]),
         raw:
           payload
           |> Map.put_new("version", @version)
       }}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:judge_result_invalid_json, error.data}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_proposal_file?(artifact_path) do
    with true <- File.regular?(artifact_path),
         {:ok, contents} <- File.read(artifact_path),
         {:ok, %{} = payload} <- Jason.decode(contents),
         {:ok, tasks} <- normalize_plan_tasks(payload["tasks"]),
         true <- meaningful_text?(payload["summary"]),
         true <- meaningful_text?(payload["rationale"]),
         true <- meaningful_tasks?(tasks) do
      true
    else
      _error -> false
    end
  end

  defp valid_plan_file?(artifact_path) do
    with true <- File.regular?(artifact_path),
         {:ok, contents} <- File.read(artifact_path),
         {:ok, %{} = payload} <- Jason.decode(contents),
         {:ok, tasks} <- normalize_plan_tasks(payload["tasks"]),
         true <- meaningful_text?(payload["summary"]),
         true <- meaningful_tasks?(tasks) do
      case string_or_nil(payload["next_task_id"]) do
        nil -> false
        task_id -> meaningful_identifier?(task_id)
      end
    else
      _error -> false
    end
  end

  defp valid_judge_file?(artifact_path) do
    with true <- File.regular?(artifact_path),
         {:ok, contents} <- File.read(artifact_path),
         {:ok, %{} = payload} <- Jason.decode(contents),
         {:ok, _decision} <- normalize_judge_decision(payload["decision"]),
         true <- meaningful_text?(payload["summary"]) do
      true
    else
      _error -> false
    end
  end

  defp normalize_judge_decision(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "continue" -> {:ok, :continue}
      "done" -> {:ok, :done}
      "blocked" -> {:ok, :blocked}
      other -> {:error, {:judge_result_invalid_decision, other}}
    end
  end

  defp normalize_judge_decision(_value), do: {:error, :judge_result_missing_decision}

  defp normalize_plan_tasks(tasks) when is_list(tasks), do: {:ok, tasks}
  defp normalize_plan_tasks(nil), do: {:error, :plan_missing_tasks}
  defp normalize_plan_tasks(_tasks), do: {:error, :plan_invalid_tasks}

  defp meaningful_tasks?(tasks) when is_list(tasks) do
    Enum.any?(tasks, fn
      %{} = task ->
        meaningful_identifier?(task["id"] || task[:id]) and
          meaningful_text?(task["title"] || task[:title]) and
          meaningful_text?(task["instructions"] || task[:instructions])

      _other ->
        false
    end)
  end

  defp meaningful_tasks?(_tasks), do: false

  defp meaningful_identifier?(value) when is_binary(value) do
    case String.trim(value) do
      "" -> false
      "..." -> false
      _identifier -> true
    end
  end

  defp meaningful_identifier?(_value), do: false

  defp meaningful_text?(value) when is_binary(value) do
    case String.trim(value) do
      "" -> false
      "..." -> false
      "TODO" -> false
      "TBD" -> false
      text -> String.length(text) >= 3
    end
  end

  defp meaningful_text?(_value), do: false

  defp string_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_or_nil(_value), do: nil

  defp proposal_paths_for_artifacts(workspace, planner_count)
       when is_binary(workspace) and is_integer(planner_count) and planner_count > 0 do
    proposal_paths(workspace, planner_count)
  end

  defp proposal_paths_for_artifacts(_workspace, _planner_count), do: []

  defp proposal_path_for_artifacts(workspace, planner_index)
       when is_binary(workspace) and is_integer(planner_index) and planner_index > 0 do
    proposal_path(workspace, planner_index)
  end

  defp proposal_path_for_artifacts(_workspace, _planner_index), do: nil

  defp write_json_file(path, %{} = payload) when is_binary(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         encoded <- Jason.encode_to_iodata!(payload),
         :ok <- File.write(path, encoded) do
      :ok
    end
  end
end
