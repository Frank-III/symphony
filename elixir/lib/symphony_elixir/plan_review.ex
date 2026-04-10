defmodule SymphonyElixir.PlanReview do
  @moduledoc false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.OrchestrationFiles

  @marker "## Symphony Plan Review"
  @review_state "Human Review"
  @resume_state "In Progress"
  @replan_state "Rework"

  @spec marker() :: String.t()
  def marker, do: @marker

  @spec review_state() :: String.t()
  def review_state, do: @review_state

  @spec resume_state() :: String.t()
  def resume_state, do: @resume_state

  @spec render(Issue.t(), OrchestrationFiles.plan_result(), keyword()) :: String.t()
  def render(%Issue{} = issue, %{raw: raw} = plan_result, opts \\ []) do
    cycle = Keyword.get(opts, :cycle)
    review_state = Keyword.get(opts, :review_state, @review_state)
    selected = selected_proposals(raw)
    tasks = task_lines(raw)

    [
      @marker,
      "",
      "Issue: `#{issue.identifier}`",
      maybe_cycle_line(cycle),
      summary_line(plan_result.summary),
      selected_line(selected),
      next_task_line(plan_result.next_task_id),
      "",
      "### Tasks",
      tasks,
      "",
      "### Approval",
      "- Move the issue to `#{@resume_state}` to approve this plan and start implementation.",
      "- Move the issue to `#{@replan_state}` to discard this plan and request replanning.",
      "- While the issue stays in `#{review_state}`, Symphony will wait and not start the worker.",
      "",
      "_This comment is managed by Symphony and will be refreshed when the plan changes._"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp maybe_cycle_line(cycle) when is_integer(cycle), do: "Cycle: `#{cycle}`"
  defp maybe_cycle_line(_cycle), do: nil

  defp summary_line(summary) when is_binary(summary), do: "Summary: #{summary}"
  defp summary_line(_summary), do: "Summary: No summary provided."

  defp selected_line([]), do: nil
  defp selected_line(selected), do: "Selected proposals: `#{Enum.join(selected, ", ")}`"

  defp next_task_line(next_task_id) when is_binary(next_task_id), do: "Next task: `#{next_task_id}`"
  defp next_task_line(_next_task_id), do: nil

  defp selected_proposals(%{"selected_proposals" => values}) when is_list(values) do
    Enum.map(values, &to_string/1)
  end

  defp selected_proposals(_raw), do: []

  defp task_lines(%{"tasks" => tasks}) when is_list(tasks) and tasks != [] do
    tasks
    |> Enum.map_join("\n", fn task ->
      id = task_value(task, "id")
      title = task_value(task, "title")
      instructions = task_value(task, "instructions")

      base =
        case {id, title} do
          {nil, nil} -> "- Untitled task"
          {nil, task_title} -> "- #{task_title}"
          {task_id, nil} -> "- `#{task_id}`"
          {task_id, task_title} -> "- `#{task_id}`: #{task_title}"
        end

      if instructions do
        "#{base}\n  Instructions: #{instructions}"
      else
        base
      end
    end)
  end

  defp task_lines(_raw), do: "- No tasks provided."

  defp task_value(%{} = task, key) do
    case Map.get(task, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end
end
