defmodule SymphonyElixir.RuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.RuntimeProfile
  alias SymphonyElixir.Runtime.{ACPAdapter, DirectCodexAdapter, Profile, Registry}

  # -- Schema: Legacy codex-only config (no runtimes key) --

  test "legacy config without runtimes parses successfully" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, settings} = Config.settings()
    assert settings.runtimes == %{}
    assert settings.planner_runtime == nil
    assert settings.worker_runtime == nil
    assert settings.judge_runtime == nil
  end

  test "materialize_codex_default_profile builds profile from codex block" do
    write_workflow_file!(Workflow.workflow_file_path())
    settings = Config.settings!()

    profile = Schema.materialize_codex_default_profile(settings)

    assert %RuntimeProfile{} = profile
    assert profile.name == "codex"
    assert profile.adapter == "direct"
    assert profile.provider == "codex"
    assert profile.command == "codex app-server"
    assert profile.thread_sandbox == "workspace-write"
  end

  # -- Schema: Multi-profile config --

  test "config with runtimes parses named profiles" do
    workflow_content = """
    ---
    tracker:
      kind: "memory"
    runtimes:
      claude_acp:
        adapter: "acp"
        provider: "claude"
        endpoint: "https://acp.example.com"
        model: "claude-sonnet-4-6"
      codex_direct:
        adapter: "direct"
        provider: "codex"
        command: "codex app-server"
    worker_runtime: "codex_direct"
    planner_runtime: "claude_acp"
    ---
    prompt
    """

    File.write!(Workflow.workflow_file_path(), workflow_content)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    assert {:ok, settings} = Config.settings()
    assert map_size(settings.runtimes) == 2

    assert %RuntimeProfile{adapter: "acp", provider: "claude"} = settings.runtimes["claude_acp"]
    assert %RuntimeProfile{adapter: "direct", provider: "codex"} = settings.runtimes["codex_direct"]

    assert settings.planner_runtime == "claude_acp"
    assert settings.worker_runtime == "codex_direct"
  end

  test "role runtime referencing undefined profile fails validation" do
    workflow_content = """
    ---
    tracker:
      kind: "memory"
    worker_runtime: "nonexistent"
    ---
    prompt
    """

    File.write!(Workflow.workflow_file_path(), workflow_content)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "nonexistent"
  end

  # -- RuntimeProfile parsing --

  test "RuntimeProfile changeset validates adapter and provider" do
    valid = %{"name" => "test", "adapter" => "acp", "provider" => "claude"}
    assert {:ok, _} = RuntimeProfile.changeset(%RuntimeProfile{}, valid) |> Ecto.Changeset.apply_action(:validate)

    invalid_adapter = %{"name" => "test", "adapter" => "unknown", "provider" => "claude"}

    assert {:error, changeset} =
             RuntimeProfile.changeset(%RuntimeProfile{}, invalid_adapter) |> Ecto.Changeset.apply_action(:validate)

    assert changeset.errors[:adapter]

    invalid_provider = %{"name" => "test", "adapter" => "acp", "provider" => "unknown"}

    assert {:error, changeset} =
             RuntimeProfile.changeset(%RuntimeProfile{}, invalid_provider) |> Ecto.Changeset.apply_action(:validate)

    assert changeset.errors[:provider]
  end

  test "parse_runtime_profiles parses a map of profiles" do
    raw = %{
      "pi_acp" => %{"adapter" => "acp", "provider" => "pi", "endpoint" => "https://pi.example.com"},
      "opencode_acp" => %{"adapter" => "acp", "provider" => "opencode", "endpoint" => "https://oc.example.com"}
    }

    assert {:ok, profiles} = Schema.parse_runtime_profiles(raw)
    assert map_size(profiles) == 2
    assert %RuntimeProfile{provider: "pi"} = profiles["pi_acp"]
    assert %RuntimeProfile{provider: "opencode"} = profiles["opencode_acp"]
  end

  # -- Registry resolution --

  test "resolve_for_role returns default codex profile when no runtimes configured" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, %Profile{} = resolved} = Registry.resolve_for_role(:worker)
    assert resolved.config.name == "codex"
    assert resolved.config.provider == "codex"
    assert resolved.adapter_module == DirectCodexAdapter
  end

  test "resolve_for_role returns configured profile" do
    workflow_content = """
    ---
    tracker:
      kind: "memory"
    runtimes:
      claude_worker:
        adapter: "acp"
        provider: "claude"
        endpoint: "https://acp.example.com"
    worker_runtime: "claude_worker"
    ---
    prompt
    """

    File.write!(Workflow.workflow_file_path(), workflow_content)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    assert {:ok, %Profile{} = resolved} = Registry.resolve_for_role(:worker)
    assert resolved.config.name == "claude_worker"
    assert resolved.config.provider == "claude"
    assert resolved.adapter_module == ACPAdapter
  end

  test "resolve_default returns codex direct profile" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, %Profile{} = resolved} = Registry.resolve_default()
    assert resolved.config.name == "codex"
    assert resolved.adapter_module == DirectCodexAdapter
  end

  test "list_profiles returns all registered profiles" do
    workflow_content = """
    ---
    tracker:
      kind: "memory"
    runtimes:
      claude_acp:
        adapter: "acp"
        provider: "claude"
        endpoint: "https://acp.example.com"
      codex_direct:
        adapter: "direct"
        provider: "codex"
        command: "codex app-server"
    ---
    prompt
    """

    File.write!(Workflow.workflow_file_path(), workflow_content)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    assert {:ok, profiles} = Registry.list_profiles()
    assert map_size(profiles) == 2
    assert %Profile{adapter_module: ACPAdapter} = profiles["claude_acp"]
    assert %Profile{adapter_module: DirectCodexAdapter} = profiles["codex_direct"]
  end

  # -- Mixed direct + ACP selection --

  test "different roles can use different runtime adapters" do
    workflow_content = """
    ---
    tracker:
      kind: "memory"
    runtimes:
      claude_planner:
        adapter: "acp"
        provider: "claude"
        endpoint: "https://acp.example.com"
      codex_worker:
        adapter: "direct"
        provider: "codex"
        command: "codex app-server"
      pi_judge:
        adapter: "acp"
        provider: "pi"
        endpoint: "https://pi.example.com"
    planner_runtime: "claude_planner"
    worker_runtime: "codex_worker"
    judge_runtime: "pi_judge"
    ---
    prompt
    """

    File.write!(Workflow.workflow_file_path(), workflow_content)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    assert {:ok, planner} = Registry.resolve_for_role(:planner)
    assert planner.adapter_module == ACPAdapter
    assert planner.config.provider == "claude"

    assert {:ok, worker} = Registry.resolve_for_role(:worker)
    assert worker.adapter_module == DirectCodexAdapter
    assert worker.config.provider == "codex"

    assert {:ok, judge} = Registry.resolve_for_role(:judge)
    assert judge.adapter_module == ACPAdapter
    assert judge.config.provider == "pi"
  end

  # -- Config.runtime_profile_for_role --

  test "runtime_profile_for_role falls back to codex when no runtimes" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, profile} = Config.runtime_profile_for_role(:worker)
    assert profile.name == "codex"
    assert profile.adapter == "direct"
  end

  test "runtime_profiles returns codex default when no runtimes configured" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, profiles} = Config.runtime_profiles()
    assert map_size(profiles) == 1
    assert %RuntimeProfile{name: "codex"} = profiles["codex"]
  end

  # -- Adapter module resolution --

  test "adapter_module_for returns correct modules" do
    assert {:ok, DirectCodexAdapter} = Registry.adapter_module_for("direct")
    assert {:ok, ACPAdapter} = Registry.adapter_module_for("acp")
    assert {:error, {:unknown_adapter, "bogus"}} = Registry.adapter_module_for("bogus")
  end

  # -- Profile struct --

  test "Profile.new creates resolved profile" do
    runtime_profile = %RuntimeProfile{name: "test", adapter: "direct", provider: "codex"}
    resolved = Profile.new(runtime_profile, DirectCodexAdapter)

    assert resolved.config == runtime_profile
    assert resolved.adapter_module == DirectCodexAdapter
  end

  # -- All four priority providers --

  test "all four priority providers are valid" do
    for provider <- ~w(claude codex pi opencode) do
      attrs = %{"name" => "test_#{provider}", "adapter" => "acp", "provider" => provider, "endpoint" => "https://example.com"}
      assert {:ok, profile} = RuntimeProfile.changeset(%RuntimeProfile{}, attrs) |> Ecto.Changeset.apply_action(:validate)
      assert profile.provider == provider
    end
  end
end
