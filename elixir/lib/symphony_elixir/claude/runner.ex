defmodule SymphonyElixir.Claude.Runner do
  @moduledoc """
  Thin Claude CLI runner for worker and judge phases.

  Shells out to `claude -p` with machine-readable output, explicit workspace,
  and tool permissions. Designed as a one-shot runner — phase start/finish
  events are synthesized in Elixir rather than recreating full app-server semantics.
  """

  require Logger

  @type run_result :: %{
          exit_code: integer(),
          output: String.t(),
          duration_ms: non_neg_integer()
        }

  @spec run(Path.t(), String.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(workspace, prompt, opts \\ []) do
    command = build_command(workspace, prompt, opts)
    timeout = Keyword.get(opts, :timeout_ms, 3_600_000)

    Logger.info("Claude runner starting in workspace=#{workspace}")

    start_time = System.monotonic_time(:millisecond)

    case run_command(command, workspace, timeout) do
      {output, exit_code} when is_binary(output) and is_integer(exit_code) ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        Logger.info(
          "Claude runner finished exit_code=#{exit_code} duration_ms=#{duration_ms} workspace=#{workspace}"
        )

        {:ok,
         %{
           exit_code: exit_code,
           output: output,
           duration_ms: duration_ms
         }}

      {:error, reason} ->
        {:error, {:claude_runner_failed, reason}}
    end
  end

  @spec build_command(Path.t(), String.t(), keyword()) :: [String.t()]
  def build_command(_workspace, prompt, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    mcp_servers = Keyword.get(opts, :mcp_servers, [])
    model = Keyword.get(opts, :model)

    base = ["claude", "-p", "--output-format", "json", "--max-turns", "50"]

    model_args =
      if model do
        ["--model", model]
      else
        []
      end

    tool_args =
      Enum.flat_map(tools, fn tool ->
        ["--allowedTools", tool]
      end)

    mcp_args =
      Enum.flat_map(mcp_servers, fn {name, config} ->
        ["--mcp-config", Jason.encode!(%{name => config})]
      end)

    base ++ model_args ++ tool_args ++ mcp_args ++ [prompt]
  end

  defp run_command(command, workspace, timeout) do
    [cmd | args] = command

    try do
      port =
        Port.open({:spawn_executable, System.find_executable(cmd)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, args},
          {:cd, workspace},
          {:env, build_env()}
        ])

      collect_output(port, "", timeout)
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, code}} ->
        {acc, code}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp build_env do
    # Inherit key environment variables for Claude CLI
    [
      {"HOME", System.get_env("HOME") || ""},
      {"PATH", System.get_env("PATH") || ""},
      {"ANTHROPIC_API_KEY", System.get_env("ANTHROPIC_API_KEY") || ""},
      {"CLAUDE_CODE_USE_BEDROCK", System.get_env("CLAUDE_CODE_USE_BEDROCK") || ""},
      {"CLAUDE_CODE_USE_VERTEX", System.get_env("CLAUDE_CODE_USE_VERTEX") || ""}
    ]
    |> Enum.reject(fn {_k, v} -> v == "" end)
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end
end
