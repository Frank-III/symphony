---
tracker:
  kind: linear
  project_slug: "your-linear-project"
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/your-org/your-repo.git .
agent:
  orchestration_mode: brainstorm_arbiter_worker_judge
  brainstorm_planners: 2
  max_concurrent_agents: 2
  max_turns: 12
runtimes:
  claude_acp:
    adapter: acp
    provider: claude
    display_name: Claude ACP Adapter
    transport: stdio
    command: claude-agent-acp
  codex_acp:
    adapter: acp
    provider: codex
    display_name: Codex ACP Adapter
    transport: stdio
    command: codex-acp
  opencode_acp:
    adapter: acp
    provider: opencode
    display_name: OpenCode ACP
    transport: stdio
    command: opencode
    args: ["acp"]
planner_runtimes: ["claude_acp", "codex_acp"]
planner_runtime: claude_acp
worker_runtime: opencode_acp
judge_runtime: codex_acp
---

You are running a Symphony ACP smoke test for Linear issue `{{ issue.identifier }}`.

- Keep repository changes minimal and easy to review.
- If an ACP adapter fails to start or handshake, record the exact command and error.
- Treat missing auth, missing adapter binaries, and ACP protocol mismatches as blockers and surface
  them clearly in the workpad.
