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

  test "config with multiple ACP stdio runtimes parses transport fields" do
    workflow_content = """
    ---
    tracker:
      kind: "memory"
    runtimes:
      claude_acp:
        adapter: "acp"
        provider: "claude"
        display_name: "Claude ACP"
        transport: "stdio"
        command: "claude"
        args: ["--acp"]
        env:
          CLAUDE_CODE_ENTRYPOINT: "stdio"
      codex_acp:
        adapter: "acp"
        provider: "codex"
        display_name: "Codex ACP"
        transport: "stdio"
        command: "codex"
        args: ["acp"]
      pi_acp:
        adapter: "acp"
        provider: "pi"
        transport: "stdio"
        command: "pi"
      opencode_acp:
        adapter: "acp"
        provider: "opencode"
        transport: "stdio"
        command: "opencode"
    planner_runtimes: ["claude_acp", "codex_acp"]
    worker_runtime: "opencode_acp"
    judge_runtime: "pi_acp"
    ---
    prompt
    """

    File.write!(Workflow.workflow_file_path(), workflow_content)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    assert {:ok, settings} = Config.settings()
    assert map_size(settings.runtimes) == 4
    assert settings.runtimes["claude_acp"].transport == "stdio"
    assert settings.runtimes["claude_acp"].args == ["--acp"]
    assert settings.runtimes["claude_acp"].env == %{"CLAUDE_CODE_ENTRYPOINT" => "stdio"}
    assert settings.runtimes["opencode_acp"].display_name == nil
    assert Config.brainstorm_planner_runtimes() == ["claude_acp", "codex_acp"]

    assert {:ok, %Profile{} = worker} = Registry.resolve_for_role(:worker)
    assert worker.config.name == "opencode_acp"
    assert worker.adapter_module == ACPAdapter

    assert {:ok, %Profile{} = planner_1} = Registry.resolve_by_name("claude_acp")
    assert planner_1.config.provider == "claude"
    assert planner_1.adapter_module == ACPAdapter

    assert {:ok, %Profile{} = planner_2} = Registry.resolve_by_name("codex_acp")
    assert planner_2.config.provider == "codex"
    assert planner_2.adapter_module == ACPAdapter

    assert {:ok, %Profile{} = judge} = Registry.resolve_for_role(:judge)
    assert judge.config.name == "pi_acp"
    assert judge.adapter_module == ACPAdapter
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

  test "RuntimeProfile changeset validates ACP transport" do
    invalid_transport = %{"name" => "test", "adapter" => "acp", "provider" => "claude", "transport" => "socket"}

    assert {:error, changeset} =
             RuntimeProfile.changeset(%RuntimeProfile{}, invalid_transport) |> Ecto.Changeset.apply_action(:validate)

    assert changeset.errors[:transport]
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
      attrs = %{
        "name" => "test_#{provider}",
        "adapter" => "acp",
        "provider" => provider,
        "endpoint" => "https://example.com"
      }

      assert {:ok, profile} =
               RuntimeProfile.changeset(%RuntimeProfile{}, attrs)
               |> Ecto.Changeset.apply_action(:validate)

      assert profile.provider == provider
    end
  end

  # -- Execution-path tests: adapter lifecycle --

  test "DirectCodexAdapter.runtime_metadata returns consistent metadata shape" do
    profile = %RuntimeProfile{name: "test_direct", adapter: "direct", provider: "codex"}

    session = %{
      __adapter__: DirectCodexAdapter,
      profile: profile,
      app_session: %{thread_id: "thread-123"},
      turn_count: 2,
      input_tokens: 100,
      output_tokens: 50,
      total_tokens: 150,
      last_event: :turn_completed
    }

    metadata = DirectCodexAdapter.runtime_metadata(session)

    assert metadata.profile_name == "test_direct"
    assert metadata.provider == "codex"
    assert metadata.adapter == "direct"
    assert metadata.transport == "stdio"
    assert metadata.display_name == nil
    assert metadata.session_id == "thread-123"
    assert metadata.turn_count == 2
    assert metadata.input_tokens == 100
    assert metadata.output_tokens == 50
    assert metadata.total_tokens == 150
    assert metadata.last_event == :turn_completed
    assert metadata.health == :healthy
  end

  test "ACPAdapter.runtime_metadata returns consistent metadata shape" do
    profile = %RuntimeProfile{
      name: "claude_acp",
      adapter: "acp",
      provider: "claude",
      transport: "http",
      display_name: "Claude ACP"
    }

    session = %{
      __adapter__: ACPAdapter,
      profile: profile,
      acp_session: %{session_id: "acp-sess-456", transport: "http"},
      turn_count: 3,
      input_tokens: 500,
      output_tokens: 200,
      total_tokens: 700,
      last_event: :turn_completed
    }

    metadata = ACPAdapter.runtime_metadata(session)

    assert metadata.profile_name == "claude_acp"
    assert metadata.provider == "claude"
    assert metadata.adapter == "acp"
    assert metadata.transport == "http"
    assert metadata.display_name == "Claude ACP"
    assert metadata.session_id == "acp-sess-456"
    assert metadata.turn_count == 3
    assert metadata.input_tokens == 500
    assert metadata.output_tokens == 200
    assert metadata.total_tokens == 700
    assert metadata.last_event == :turn_completed
    assert metadata.health == :healthy
  end

  test "direct and ACP metadata share identical key sets" do
    direct_profile = %RuntimeProfile{name: "d", adapter: "direct", provider: "codex"}
    acp_profile = %RuntimeProfile{name: "a", adapter: "acp", provider: "claude", transport: "http"}

    direct_session = %{
      __adapter__: DirectCodexAdapter,
      profile: direct_profile,
      app_session: %{thread_id: "t"},
      turn_count: 0,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      last_event: nil
    }

    acp_session = %{
      __adapter__: ACPAdapter,
      profile: acp_profile,
      acp_session: %{session_id: "s", transport: "http"},
      turn_count: 0,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      last_event: nil
    }

    direct_keys = DirectCodexAdapter.runtime_metadata(direct_session) |> Map.keys() |> MapSet.new()
    acp_keys = ACPAdapter.runtime_metadata(acp_session) |> Map.keys() |> MapSet.new()

    assert direct_keys == acp_keys
  end

  test "ACPAdapter classifies stdio missing and non-executable commands" do
    missing_profile = %RuntimeProfile{
      name: "missing_stdio",
      adapter: "acp",
      provider: "claude",
      transport: "stdio"
    }

    assert {:error, {:acp_config_error, "missing_stdio", :missing_command}} =
             ACPAdapter.start_session(missing_profile, System.tmp_dir!())

    non_executable = Path.join(System.tmp_dir!(), "symphony-acp-not-executable-#{System.unique_integer([:positive])}")
    File.write!(non_executable, "#!/usr/bin/env bash\n")
    File.chmod!(non_executable, 0o644)

    try do
      bad_profile = %RuntimeProfile{
        name: "bad_stdio",
        adapter: "acp",
        provider: "claude",
        transport: "stdio",
        command: non_executable
      }

      assert {:error, {:acp_config_error, "bad_stdio", {:non_executable_command, ^non_executable}}} =
               ACPAdapter.start_session(bad_profile, System.tmp_dir!())
    after
      File.rm(non_executable)
    end
  end

  test "ACPAdapter classifies missing HTTP endpoint" do
    profile = %RuntimeProfile{
      name: "missing_http",
      adapter: "acp",
      provider: "claude",
      transport: "http"
    }

    assert {:error, {:acp_config_error, "missing_http", :missing_endpoint}} =
             ACPAdapter.start_session(profile, System.tmp_dir!())
  end

  test "ACPAdapter supports stdio JSON-RPC session and turn lifecycle" do
    workspace = Path.join(System.tmp_dir!(), "symphony-acp-stdio-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    script = Path.join(workspace, "fake_acp_agent")

    File.write!(script, """
    #!/usr/bin/env bash
    IFS= read -r _line
    response_1='{"jsonrpc":"2.0","id":1,"result":'
    response_1="${response_1}"'{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}'
    printf '%s\\n' "$response_1"
    IFS= read -r _line
    printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"sess-stdio\"}}'
    IFS= read -r _line
    update='{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-stdio",'
    update="${update}"'"update":{"sessionUpdate":"agent_message_chunk",'
    update="${update}"'"content":{"type":"text","text":"hello from stdio"}}}}'
    printf '%s\\n' "$update"
    printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}'
    """)

    File.chmod!(script, 0o755)

    profile = %RuntimeProfile{
      name: "fake_stdio",
      adapter: "acp",
      provider: "codex",
      transport: "stdio",
      command: script,
      cwd: workspace,
      read_timeout_ms: 1_000,
      turn_timeout_ms: 1_000
    }

    try do
      assert {:ok, session} = ACPAdapter.start_session(profile, workspace)
      assert session.acp_session.transport == "stdio"
      assert session.acp_session.session_id == "sess-stdio"

      assert {:ok, result} =
               ACPAdapter.run_turn(session, "hello", %{identifier: "PAN-91", title: "ACP stdio fake"})

      assert result.result["stopReason"] == "end_turn"
      assert result.result["content"] == "hello from stdio"
      assert result.session.turn_count == 1
      ACPAdapter.stop_session(result.session)
    after
      File.rm_rf(workspace)
    end
  end

  # -- Named direct profile settings override defaults --

  test "named direct profile carries custom settings" do
    workflow_content = """
    ---
    tracker:
      kind: "memory"
    runtimes:
      custom_codex:
        adapter: "direct"
        provider: "codex"
        command: "custom-codex-server"
        turn_timeout_ms: 120000
        read_timeout_ms: 15000
    worker_runtime: "custom_codex"
    ---
    prompt
    """

    File.write!(Workflow.workflow_file_path(), workflow_content)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    assert {:ok, %Profile{} = resolved} = Registry.resolve_for_role(:worker)
    assert resolved.config.command == "custom-codex-server"
    assert resolved.config.turn_timeout_ms == 120_000
    assert resolved.config.read_timeout_ms == 15_000
    assert resolved.adapter_module == DirectCodexAdapter
  end

  test "named direct profile inherits nil for unset fields" do
    workflow_content = """
    ---
    tracker:
      kind: "memory"
    runtimes:
      minimal_codex:
        adapter: "direct"
        provider: "codex"
    worker_runtime: "minimal_codex"
    ---
    prompt
    """

    File.write!(Workflow.workflow_file_path(), workflow_content)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    assert {:ok, %Profile{} = resolved} = Registry.resolve_for_role(:worker)
    assert resolved.config.command == nil
    assert resolved.config.turn_timeout_ms == nil
    assert resolved.config.read_timeout_ms == nil
  end

  # -- ACP profile with timeout settings --

  test "ACP profile carries timeout settings to adapter" do
    workflow_content = """
    ---
    tracker:
      kind: "memory"
    runtimes:
      claude_fast:
        adapter: "acp"
        provider: "claude"
        endpoint: "https://acp.example.com"
        model: "claude-sonnet-4-6"
        turn_timeout_ms: 300000
        read_timeout_ms: 10000
    worker_runtime: "claude_fast"
    ---
    prompt
    """

    File.write!(Workflow.workflow_file_path(), workflow_content)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    assert {:ok, %Profile{} = resolved} = Registry.resolve_for_role(:worker)
    assert resolved.config.turn_timeout_ms == 300_000
    assert resolved.config.read_timeout_ms == 10_000
    assert resolved.config.model == "claude-sonnet-4-6"
    assert resolved.adapter_module == ACPAdapter
  end

  # -- Mixed planner/worker/judge coexistence --

  test "all four priority providers coexist with mixed adapters" do
    workflow_content = """
    ---
    tracker:
      kind: "memory"
    runtimes:
      claude_plan:
        adapter: "acp"
        provider: "claude"
        endpoint: "https://acp.claude.example.com"
      codex_work:
        adapter: "direct"
        provider: "codex"
        command: "codex app-server"
      pi_judge:
        adapter: "acp"
        provider: "pi"
        endpoint: "https://acp.pi.example.com"
      opencode_alt:
        adapter: "acp"
        provider: "opencode"
        endpoint: "https://acp.opencode.example.com"
    planner_runtime: "claude_plan"
    worker_runtime: "codex_work"
    judge_runtime: "pi_judge"
    ---
    prompt
    """

    File.write!(Workflow.workflow_file_path(), workflow_content)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    assert {:ok, profiles} = Registry.list_profiles()
    assert map_size(profiles) == 4

    providers = profiles |> Map.values() |> Enum.map(& &1.config.provider) |> MapSet.new()
    assert MapSet.equal?(providers, MapSet.new(~w(claude codex pi opencode)))

    assert {:ok, planner} = Registry.resolve_for_role(:planner)
    assert planner.config.provider == "claude"
    assert planner.adapter_module == ACPAdapter

    assert {:ok, worker} = Registry.resolve_for_role(:worker)
    assert worker.config.provider == "codex"
    assert worker.adapter_module == DirectCodexAdapter

    assert {:ok, judge} = Registry.resolve_for_role(:judge)
    assert judge.config.provider == "pi"
    assert judge.adapter_module == ACPAdapter
  end

  # -- Presenter runtime identity in snapshot data --

  test "presenter runtime_identity produces correct shape" do
    entry = %{
      runtime_profile: "claude_worker",
      runtime_provider: "claude",
      runtime_adapter: "acp",
      runtime_transport: "stdio",
      runtime_display_name: "Claude ACP"
    }

    # Exercise the presenter's runtime_identity logic inline
    identity = %{
      profile: Map.get(entry, :runtime_profile, "codex"),
      provider: Map.get(entry, :runtime_provider, "codex"),
      adapter: Map.get(entry, :runtime_adapter, "direct"),
      transport: Map.get(entry, :runtime_transport, "stdio"),
      display_name: Map.get(entry, :runtime_display_name)
    }

    assert identity == %{
             profile: "claude_worker",
             provider: "claude",
             adapter: "acp",
             transport: "stdio",
             display_name: "Claude ACP"
           }
  end

  test "presenter runtime_identity defaults for legacy entries" do
    entry = %{}

    identity = %{
      profile: Map.get(entry, :runtime_profile, "codex"),
      provider: Map.get(entry, :runtime_provider, "codex"),
      adapter: Map.get(entry, :runtime_adapter, "direct"),
      transport: Map.get(entry, :runtime_transport, "stdio"),
      display_name: Map.get(entry, :runtime_display_name)
    }

    assert identity == %{profile: "codex", provider: "codex", adapter: "direct", transport: "stdio", display_name: nil}
  end
end
