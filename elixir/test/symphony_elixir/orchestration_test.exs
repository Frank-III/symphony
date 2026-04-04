defmodule SymphonyElixir.OrchestrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestration

  describe "config parsing with orchestration block" do
    test "defaults to single mode when orchestration block is absent" do
      settings = Config.settings!()
      assert settings.orchestration.mode == "single"
      assert settings.orchestration.planner_count == 2
      assert settings.orchestration.artifact_dir == ".symphony/orchestration"
      assert settings.orchestration.primary_agent_runtime == "codex"
      assert settings.orchestration.role_overrides == %{}
    end

    test "parses brainstorm_arbiter_worker_judge mode" do
      workflow_file = Workflow.workflow_file_path()

      write_workflow_file!(workflow_file,
        orchestration_mode: "brainstorm_arbiter_worker_judge",
        orchestration_planner_count: 3,
        orchestration_artifact_dir: ".custom/artifacts",
        orchestration_primary_agent_runtime: "claude"
      )

      settings = Config.settings!()
      assert settings.orchestration.mode == "brainstorm_arbiter_worker_judge"
      assert settings.orchestration.planner_count == 3
      assert settings.orchestration.artifact_dir == ".custom/artifacts"
      assert settings.orchestration.primary_agent_runtime == "claude"
    end

    test "rejects invalid mode" do
      workflow_file = Workflow.workflow_file_path()

      write_workflow_file!(workflow_file, orchestration_mode: "invalid_mode")

      assert {:error, {:invalid_workflow_config, msg}} = Config.settings()
      assert msg =~ "mode"
    end

    test "rejects planner_count less than 2" do
      workflow_file = Workflow.workflow_file_path()

      write_workflow_file!(workflow_file,
        orchestration_mode: "brainstorm_arbiter_worker_judge",
        orchestration_planner_count: 1
      )

      assert {:error, {:invalid_workflow_config, msg}} = Config.settings()
      assert msg =~ "planner_count"
    end

    test "config convenience getters work" do
      assert Config.orchestration_mode() == "single"
      refute Config.brainstorm_mode?()
      assert Config.planner_count() == 2
      assert Config.orchestration_artifact_dir() == ".symphony/orchestration"
    end

    test "brainstorm_mode? returns true for brainstorm mode" do
      workflow_file = Workflow.workflow_file_path()

      write_workflow_file!(workflow_file,
        orchestration_mode: "brainstorm_arbiter_worker_judge"
      )

      assert Config.brainstorm_mode?()
    end
  end

  describe "artifact paths" do
    test "proposals_dir returns correct path" do
      assert Orchestration.proposals_dir("/workspace") ==
               "/workspace/.symphony/orchestration/proposals"
    end

    test "proposal_path returns indexed path" do
      assert Orchestration.proposal_path("/workspace", 1) ==
               "/workspace/.symphony/orchestration/proposals/planner-1.json"

      assert Orchestration.proposal_path("/workspace", 2) ==
               "/workspace/.symphony/orchestration/proposals/planner-2.json"
    end

    test "plan_path returns correct path" do
      assert Orchestration.plan_path("/workspace") ==
               "/workspace/.symphony/orchestration/plan.json"
    end

    test "judge_path returns correct path" do
      assert Orchestration.judge_path("/workspace") ==
               "/workspace/.symphony/orchestration/judge.json"
    end

    test "ensure_artifact_dirs! creates proposals directory" do
      workspace = Path.join(System.tmp_dir!(), "symphony-test-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(workspace) end)

      Orchestration.ensure_artifact_dirs!(workspace)
      assert File.dir?(Orchestration.proposals_dir(workspace))
    end
  end

  describe "artifact validation" do
    setup do
      workspace = Path.join(System.tmp_dir!(), "symphony-test-#{System.unique_integer([:positive])}")
      Orchestration.ensure_artifact_dirs!(workspace)
      on_exit(fn -> File.rm_rf!(workspace) end)
      %{workspace: workspace}
    end

    test "validate_proposal accepts valid proposal", %{workspace: workspace} do
      path = Orchestration.proposal_path(workspace, 1)

      File.write!(path, Jason.encode!(%{
        "version" => 1,
        "summary" => "Test proposal",
        "tasks" => []
      }))

      assert {:ok, proposal} = Orchestration.validate_proposal(path)
      assert proposal["summary"] == "Test proposal"
    end

    test "validate_proposal rejects missing summary", %{workspace: workspace} do
      path = Orchestration.proposal_path(workspace, 1)
      File.write!(path, Jason.encode!(%{"tasks" => []}))

      assert {:error, {:invalid_proposal, ^path, :missing_summary}} =
               Orchestration.validate_proposal(path)
    end

    test "validate_plan accepts valid plan", %{workspace: workspace} do
      path = Orchestration.plan_path(workspace)

      File.write!(path, Jason.encode!(%{
        "version" => 1,
        "tasks" => [%{"id" => "T1", "title" => "Task 1"}],
        "next_task_id" => "T1"
      }))

      assert {:ok, plan} = Orchestration.validate_plan(path)
      assert length(plan["tasks"]) == 1
    end

    test "validate_plan rejects missing tasks", %{workspace: workspace} do
      path = Orchestration.plan_path(workspace)
      File.write!(path, Jason.encode!(%{"summary" => "No tasks"}))

      assert {:error, {:invalid_plan, ^path, :missing_tasks}} =
               Orchestration.validate_plan(path)
    end

    test "validate_judge accepts valid judge artifact", %{workspace: workspace} do
      path = Orchestration.judge_path(workspace)

      File.write!(path, Jason.encode!(%{
        "decision" => "accept",
        "rationale" => "All criteria met",
        "linear_tool_usage" => [%{"query" => "query { viewer { id } }"}]
      }))

      assert {:ok, judge} = Orchestration.validate_judge(path)
      assert judge["decision"] == "accept"
    end

    test "validate_judge rejects missing decision", %{workspace: workspace} do
      path = Orchestration.judge_path(workspace)
      File.write!(path, Jason.encode!(%{"rationale" => "No decision"}))

      assert {:error, {:invalid_judge, ^path, :missing_decision}} =
               Orchestration.validate_judge(path)
    end

    test "list_proposals returns sorted proposal files", %{workspace: workspace} do
      File.write!(Orchestration.proposal_path(workspace, 2), "{}")
      File.write!(Orchestration.proposal_path(workspace, 1), "{}")

      proposals = Orchestration.list_proposals(workspace)
      assert length(proposals) == 2
      assert String.ends_with?(Enum.at(proposals, 0), "planner-1.json")
      assert String.ends_with?(Enum.at(proposals, 1), "planner-2.json")
    end

    test "list_proposals returns empty for missing directory" do
      assert Orchestration.list_proposals("/nonexistent/path") == []
    end
  end

  describe "phase prompts" do
    setup do
      issue = %Issue{
        id: "test-id",
        identifier: "PAN-99",
        title: "Test issue",
        description: "Test description"
      }

      %{issue: issue}
    end

    test "brainstorm prompt includes planner index", %{issue: issue} do
      prompt =
        Orchestration.phase_prompt(:brainstorm, %{
          issue: issue,
          planner_index: 1,
          proposals_dir: "/workspace/proposals"
        })

      assert prompt =~ "planner 1"
      assert prompt =~ "PAN-99"
      assert prompt =~ "planner-1.json"
    end

    test "arbiter prompt includes proposal paths", %{issue: issue} do
      prompt =
        Orchestration.phase_prompt(:arbiter, %{
          issue: issue,
          proposal_paths: ["/workspace/proposals/planner-1.json", "/workspace/proposals/planner-2.json"],
          plan_path: "/workspace/plan.json"
        })

      assert prompt =~ "arbiter"
      assert prompt =~ "planner-1.json"
      assert prompt =~ "planner-2.json"
      assert prompt =~ "plan.json"
    end

    test "worker prompt includes cycle info", %{issue: issue} do
      prompt =
        Orchestration.phase_prompt(:worker, %{
          issue: issue,
          plan_path: "/workspace/plan.json",
          cycle: 1,
          total_cycles: 20
        })

      assert prompt =~ "cycle 1 of 20"
      assert prompt =~ "plan.json"
    end

    test "judge prompt requires linear_graphql usage", %{issue: issue} do
      prompt =
        Orchestration.phase_prompt(:judge, %{
          issue: issue,
          plan_path: "/workspace/plan.json",
          judge_path: "/workspace/judge.json"
        })

      assert prompt =~ "linear_graphql"
      assert prompt =~ "judge.json"
      assert prompt =~ "decision"
    end
  end

  describe "runtime_for_phase" do
    test "brainstorm uses codex" do
      assert Orchestration.runtime_for_phase(:brainstorm) == "codex"
    end

    test "arbiter uses codex" do
      assert Orchestration.runtime_for_phase(:arbiter) == "codex"
    end

    test "worker defaults to claude" do
      assert Orchestration.runtime_for_phase(:worker) == "claude"
    end

    test "judge defaults to claude" do
      assert Orchestration.runtime_for_phase(:judge) == "claude"
    end
  end

  describe "claude runner command construction" do
    alias SymphonyElixir.Claude.Runner

    test "builds basic command" do
      cmd = Runner.build_command("/workspace", "Do the thing")
      assert "claude" in cmd
      assert "-p" in cmd
      assert "--output-format" in cmd
      assert "json" in cmd
      assert "Do the thing" in cmd
    end

    test "includes model flag when specified" do
      cmd = Runner.build_command("/workspace", "prompt", model: "opus")
      assert "--model" in cmd
      assert "opus" in cmd
    end

    test "includes tool flags" do
      cmd = Runner.build_command("/workspace", "prompt", tools: ["tool1", "tool2"])
      assert Enum.count(cmd, &(&1 == "--allowedTools")) == 2
    end
  end
end
