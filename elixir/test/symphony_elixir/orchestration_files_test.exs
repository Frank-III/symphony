defmodule SymphonyElixir.OrchestrationFilesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.OrchestrationFiles

  test "orchestration files prepare paths and parse plan and judge results" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestration-files-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace) end)

    assert :ok = OrchestrationFiles.prepare(workspace)

    assert OrchestrationFiles.artifact_paths(nil) == %{
             "artifact_writer_path" => nil,
             "orchestration_dir" => nil,
             "proposal_dir" => nil,
             "proposal_paths" => [],
             "current_proposal_path" => nil,
             "plan_path" => nil,
             "judge_path" => nil,
             "plan_review_path" => nil
           }

    assert File.dir?(OrchestrationFiles.orchestration_dir(workspace))
    assert File.dir?(OrchestrationFiles.proposal_dir(workspace))
    assert OrchestrationFiles.proposal_path(workspace, 2) =~ "planner-2.json"
    assert Path.type(OrchestrationFiles.artifact_writer_path(workspace)) == :absolute
    assert File.regular?(OrchestrationFiles.artifact_writer_path(workspace))

    assert OrchestrationFiles.artifact_paths(workspace, planner_count: 3, planner_index: 2) == %{
             "orchestration_dir" => OrchestrationFiles.orchestration_dir(workspace),
             "proposal_dir" => OrchestrationFiles.proposal_dir(workspace),
             "proposal_paths" => OrchestrationFiles.proposal_paths(workspace, 3),
             "current_proposal_path" => OrchestrationFiles.proposal_path(workspace, 2),
             "artifact_writer_path" => OrchestrationFiles.artifact_writer_path(workspace),
             "plan_path" => OrchestrationFiles.plan_path(workspace),
             "judge_path" => OrchestrationFiles.judge_path(workspace),
             "plan_review_path" => OrchestrationFiles.plan_review_path(workspace)
           }

    File.write!(
      OrchestrationFiles.plan_path(workspace),
      Jason.encode!(%{
        summary: "  synthesized plan  ",
        tasks: [%{"id" => "T1"}, %{"id" => "T2"}],
        next_task_id: " T1 "
      })
    )

    assert {:ok, plan_result} = OrchestrationFiles.load_plan(workspace)
    assert plan_result.summary == "synthesized plan"
    assert plan_result.next_task_id == "T1"
    assert plan_result.task_count == 2
    assert plan_result.raw["version"] == 1

    assert :ok = OrchestrationFiles.clear_plan(workspace)
    assert {:error, :plan_missing} = OrchestrationFiles.load_plan(workspace)

    assert :ok = OrchestrationFiles.clear_judge_result(workspace)
    assert {:error, :judge_result_missing} = OrchestrationFiles.load_judge_result(workspace)

    File.write!(
      OrchestrationFiles.judge_path(workspace),
      Jason.encode!(%{
        decision: " BLOCKED ",
        summary: "  waiting on credentials  ",
        next_focus: "   "
      })
    )

    assert {:ok, result} = OrchestrationFiles.load_judge_result(workspace)
    assert result.decision == :blocked
    assert result.summary == "waiting on credentials"
    assert result.next_focus == nil
    assert result.raw["version"] == 1

    File.write!(
      OrchestrationFiles.judge_path(workspace),
      Jason.encode!(%{
        decision: "done",
        summary: 7,
        next_focus: ["ship"]
      })
    )

    assert {:ok, result_with_non_strings} = OrchestrationFiles.load_judge_result(workspace)
    assert result_with_non_strings.summary == nil
    assert result_with_non_strings.next_focus == nil
  end

  test "orchestration files surface invalid plan/judge payloads and filesystem errors" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestration-files-errors-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace) end)

    assert :ok = OrchestrationFiles.prepare(workspace)

    assert {:error, :plan_missing} = OrchestrationFiles.load_plan(workspace)

    File.write!(OrchestrationFiles.plan_path(workspace), "{not-json")
    assert {:error, {:plan_invalid_json, "{not-json"}} = OrchestrationFiles.load_plan(workspace)

    File.write!(OrchestrationFiles.plan_path(workspace), Jason.encode!([]))
    assert {:error, :plan_invalid_shape} = OrchestrationFiles.load_plan(workspace)

    File.write!(
      OrchestrationFiles.plan_path(workspace),
      Jason.encode!(%{"summary" => "missing tasks"})
    )

    assert {:error, :plan_missing_tasks} = OrchestrationFiles.load_plan(workspace)

    File.write!(OrchestrationFiles.plan_path(workspace), Jason.encode!(%{"tasks" => %{}}))
    assert {:error, :plan_invalid_tasks} = OrchestrationFiles.load_plan(workspace)

    File.rm!(OrchestrationFiles.plan_path(workspace))
    File.mkdir_p!(OrchestrationFiles.plan_path(workspace))

    assert {:error, reason} = OrchestrationFiles.clear_plan(workspace)
    assert reason in [:eisdir, :eperm]

    assert {:error, plan_read_reason} = OrchestrationFiles.load_plan(workspace)
    assert plan_read_reason in [:eisdir, :eperm]

    File.write!(OrchestrationFiles.judge_path(workspace), "{not-json")

    assert {:error, {:judge_result_invalid_json, "{not-json"}} =
             OrchestrationFiles.load_judge_result(workspace)

    File.write!(OrchestrationFiles.judge_path(workspace), Jason.encode!(%{"decision" => "later"}))

    assert {:error, {:judge_result_invalid_decision, "later"}} =
             OrchestrationFiles.load_judge_result(workspace)

    File.write!(
      OrchestrationFiles.judge_path(workspace),
      Jason.encode!(%{"summary" => "missing"})
    )

    assert {:error, :judge_result_missing_decision} =
             OrchestrationFiles.load_judge_result(workspace)

    File.rm!(OrchestrationFiles.judge_path(workspace))
    File.mkdir_p!(OrchestrationFiles.judge_path(workspace))

    assert {:error, reason} = OrchestrationFiles.clear_judge_result(workspace)
    assert reason in [:eisdir, :eperm]
    assert {:error, read_reason} = OrchestrationFiles.load_judge_result(workspace)
    assert read_reason in [:eisdir, :eperm]
  end

  test "orchestration files report a missing plan file" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestration-files-missing-plan-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace) end)

    assert :ok = OrchestrationFiles.prepare(workspace)
    assert {:error, :plan_missing} = OrchestrationFiles.load_plan(workspace)
  end

  test "orchestration files persist and clear plan review markers" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestration-plan-review-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace) end)

    assert :ok = OrchestrationFiles.prepare(workspace)
    assert {:error, :plan_review_missing} = OrchestrationFiles.load_plan_review(workspace)

    payload = %{"cycle" => 1, "review_state" => "Human Review", "resume_state" => "In Progress"}
    assert :ok = OrchestrationFiles.write_plan_review(workspace, payload)
    assert {:ok, ^payload} = OrchestrationFiles.load_plan_review(workspace)

    assert :ok = OrchestrationFiles.clear_plan_review(workspace)
    assert {:error, :plan_review_missing} = OrchestrationFiles.load_plan_review(workspace)
  end

  test "artifact readiness requires concrete planner and plan payloads" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestration-artifact-ready-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace) end)

    assert :ok = OrchestrationFiles.prepare(workspace)

    proposal_path = OrchestrationFiles.proposal_path(workspace, 1)

    File.write!(
      proposal_path,
      Jason.encode!(%{
        version: 1,
        cycle: 1,
        planner_index: 1,
        summary: "...",
        rationale: "...",
        tasks: [%{"id" => "T1", "title" => "...", "instructions" => "..."}]
      })
    )

    refute OrchestrationFiles.artifact_ready?(proposal_path)

    File.write!(
      proposal_path,
      Jason.encode!(%{
        version: 1,
        cycle: 1,
        planner_index: 1,
        summary: "Keep ACP additive first",
        rationale: "Direct runtimes already work and ACP should stay additive.",
        tasks: [
          %{
            "id" => "T1",
            "title" => "Add generic ACP profile config",
            "instructions" => "Introduce named ACP runtime profiles without replacing direct codex or claude."
          }
        ]
      })
    )

    assert OrchestrationFiles.artifact_ready?(proposal_path)

    plan_path = OrchestrationFiles.plan_path(workspace)

    File.write!(
      plan_path,
      Jason.encode!(%{
        version: 1,
        summary: "...",
        tasks: [%{"id" => "T1", "title" => "Ship", "instructions" => "Do it"}],
        next_task_id: "T1"
      })
    )

    refute OrchestrationFiles.artifact_ready?(plan_path)

    File.write!(
      plan_path,
      Jason.encode!(%{
        version: 1,
        summary: "Generalize ACP runtime support",
        tasks: [
          %{
            "id" => "T1",
            "title" => "Add named runtime profiles",
            "instructions" => "Support mixed direct and ACP runtimes in the same workflow."
          }
        ],
        next_task_id: "T1"
      })
    )

    assert OrchestrationFiles.artifact_ready?(plan_path)
  end

  test "artifact writer helper validates and writes json objects atomically" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-artifact-writer-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace) end)

    artifact_path = Path.join(workspace, "proposal.json")
    helper_path = Path.expand("../../bin/symphony-write-artifact", __DIR__)

    {_, 0} =
      System.shell("printf '%s' '{\"summary\":\"ready\",\"tasks\":[]}' | '#{helper_path}' '#{artifact_path}' 2>&1")

    assert Jason.decode!(File.read!(artifact_path)) == %{"summary" => "ready", "tasks" => []}

    {output, 1} =
      System.shell("printf '%s' '[\"bad\"]' | '#{helper_path}' '#{artifact_path}' 2>&1")

    assert output =~ "artifact payload must be a JSON object"
  end

  test "artifact materialization extracts concrete json objects from final responses" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-artifact-materialize-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace) end)

    assert :ok = OrchestrationFiles.prepare(workspace)

    proposal_path = OrchestrationFiles.proposal_path(workspace, 2)

    assert :ok =
             OrchestrationFiles.materialize_artifact(
               proposal_path,
               """
               Final proposal:

               ```json
               {
                 "summary": "Use final-response JSON fallback for planners",
                 "rationale": "Planner runtimes already know the structure; Symphony can persist it safely.",
                 "tasks": [
                   {
                     "id": "T2",
                     "title": "Materialize planner JSON from the final response",
                     "instructions": "Parse the returned JSON and write planner-2.json when the file is still placeholder."
                   }
                 ]
               }
               ```
               """
             )

    assert OrchestrationFiles.artifact_ready?(proposal_path)

    plan_path = OrchestrationFiles.plan_path(workspace)

    assert :ok =
             OrchestrationFiles.materialize_artifact(
               plan_path,
               %{
                 "summary" => "Use returned JSON for canonical plans",
                 "tasks" => [
                   %{
                     "id" => "T1",
                     "title" => "Write plan.json from the plan-judge response",
                     "instructions" => "Persist a valid plan object when the plan judge returns JSON instead of editing the file."
                   }
                 ],
                 "next_task_id" => "T1",
                 "selected_proposals" => [1, 2]
               }
             )

    assert OrchestrationFiles.artifact_ready?(plan_path)
  end

  test "prompt builder falls back to safe orchestration defaults when config is invalid" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_runtime: "bad-runtime",
      prompt: "role={{ agent.role }} mode={{ agent.orchestration_mode }} runtime={{ agent.runtime }}"
    )

    issue = %Issue{
      identifier: "MT-ORCH-FALLBACK",
      title: "Fallback prompt defaults",
      description: "Invalid config should not break prompt rendering.",
      state: "Todo",
      url: "https://example.org/issues/MT-ORCH-FALLBACK",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue, role: "judge") ==
             "role=judge mode=single runtime=codex"
  end

  test "prompt builder normalizes unknown orchestration roles to worker guidance" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "role={{ agent.role }}",
      agent_orchestration_mode: "planner_worker_judge"
    )

    issue = %Issue{
      identifier: "MT-ORCH-WORKER",
      title: "Normalize unknown role",
      description: "Prompt builder should collapse unknown roles to worker.",
      state: "Todo",
      url: "https://example.org/issues/MT-ORCH-WORKER",
      labels: []
    }

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestration-prompt-fallback-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace) end)

    prompt =
      PromptBuilder.build_prompt(issue,
        orchestration_mode: "planner_worker_judge",
        role: :mystery_role,
        workspace: workspace
      )

    assert prompt =~ "role=worker"
    assert prompt =~ "Worker role guidance:"
    assert prompt =~ "cycle unknown"

    judge_prompt =
      PromptBuilder.build_prompt(issue,
        orchestration_mode: "planner_worker_judge",
        role: :judge,
        workspace: workspace
      )

    assert judge_prompt =~ ~s/"cycle":null/
  end

  test "prompt builder exposes brainstorm planner and arbiter artifact guidance" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt:
        "role={{ agent.role }} runtime={{ agent.runtime }} planner={{ agent.planner_index }}/{{ agent.planner_count }} proposal={{ artifacts.current_proposal_path }} count={{ artifacts.proposal_paths | size }} plan={{ artifacts.plan_path }}",
      agent_orchestration_mode: "brainstorm_arbiter_worker_judge",
      agent_planner_runtime: "claude",
      agent_judge_runtime: "claude",
      agent_brainstorm_planners: 3
    )

    issue = %Issue{
      identifier: "MT-BRAINSTORM",
      title: "Brainstorm prompt",
      description: "Prompt builder should expose brainstorm metadata.",
      state: "Todo",
      url: "https://example.org/issues/MT-BRAINSTORM",
      labels: []
    }

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-brainstorm-prompt-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace) end)

    planner_prompt =
      PromptBuilder.build_prompt(issue,
        attempt: 2,
        retry_reason: {:artifact_write_first_violation, SymphonyElixir.OrchestrationFiles.proposal_path(workspace, 2), "Read", :agent_activity},
        orchestration_mode: "brainstorm_arbiter_worker_judge",
        planner_count: 3,
        planner_index: 2,
        role: :planner,
        runtime: "claude",
        workspace: workspace
      )

    assert planner_prompt =~ "role=planner"
    assert planner_prompt =~ "planner=2/3"

    assert planner_prompt =~
             "proposal=#{SymphonyElixir.OrchestrationFiles.proposal_path(workspace, 2)}"

    assert planner_prompt =~ "count=3"
    assert planner_prompt =~ "Brainstorm planner execution contract:"
    assert planner_prompt =~ "Brainstorm planner guidance:"
    assert planner_prompt =~ SymphonyElixir.OrchestrationFiles.artifact_writer_path(workspace)
    assert planner_prompt =~ "cat <<'JSON' |"
    assert planner_prompt =~ "Planning should stay cheap."
    assert planner_prompt =~ "Do not run broad scans across the whole repo."
    assert planner_prompt =~ "Your first action must be overwriting"
    assert planner_prompt =~ "Prefer `Write`/`Edit` for the proposal file itself."
    assert planner_prompt =~ "your final response must be exactly one JSON object"
    assert planner_prompt =~ "Do not use `Glob` or `Grep` before the file already contains"
    assert planner_prompt =~ "Do not spawn sub-agents"
    assert planner_prompt =~ "A proposal is not finished until"
    assert planner_prompt =~ "As soon as that file contains your final JSON proposal, stop."
    assert planner_prompt =~ "Retry guidance:"
    assert planner_prompt =~ "The previous planner attempt ended before replacing the placeholder artifact."
    assert planner_prompt =~ "Previous failure:"
    assert planner_prompt =~ "attempted \"Read\" before overwriting"
    refute planner_prompt =~ "Start every task by opening the tracking workpad comment"

    arbiter_prompt =
      PromptBuilder.build_prompt(issue,
        attempt: 3,
        retry_reason: {:artifact_watchdog_triggered, SymphonyElixir.OrchestrationFiles.plan_path(workspace), 4, 4, :agent_activity},
        orchestration_mode: "brainstorm_arbiter_worker_judge",
        planner_count: 3,
        role: :arbiter,
        runtime: "claude",
        workspace: workspace
      )

    assert arbiter_prompt =~ "role=arbiter"
    assert arbiter_prompt =~ "planner=/3"
    assert arbiter_prompt =~ "Plan judge execution contract:"
    assert arbiter_prompt =~ "Plan judge role guidance:"
    assert arbiter_prompt =~ SymphonyElixir.OrchestrationFiles.artifact_writer_path(workspace)
    assert arbiter_prompt =~ "Plan judging should stay cheap."
    assert arbiter_prompt =~ "Your first action must be opening"
    assert arbiter_prompt =~ "Prefer `Read` for proposal/repo inspection"
    assert arbiter_prompt =~ "your final response must be exactly one JSON object"
    assert arbiter_prompt =~ "Do not use `Glob` or `Grep` before"
    assert arbiter_prompt =~ "Do not spawn sub-agents"
    assert arbiter_prompt =~ "The plan is not finished until"
    assert arbiter_prompt =~ "As soon as that file contains your final JSON plan, stop."
    assert arbiter_prompt =~ "The previous plan-judge attempt ended before replacing the placeholder artifact."
    assert arbiter_prompt =~ "hit the artifact watchdog"
    assert arbiter_prompt =~ SymphonyElixir.OrchestrationFiles.plan_path(workspace)
  end
end
