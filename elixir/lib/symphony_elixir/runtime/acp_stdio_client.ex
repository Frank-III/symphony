defmodule SymphonyElixir.Runtime.ACPStdioClient do
  @moduledoc """
  Local stdio JSON-RPC transport for Agent Client Protocol runtimes.

  This module implements the ACP transport and lifecycle primitives that are
  common across Claude, Codex, Pi, and OpenCode-style providers. Provider
  differences are expressed in runtime profile data rather than orchestration
  call sites.
  """

  import Bitwise
  require Logger

  alias SymphonyElixir.Config.Schema.RuntimeProfile

  @protocol_version 1
  @initialize_id 1
  @session_new_id 2
  @session_prompt_id 3
  @port_line_bytes 1_048_576
  @default_turn_timeout_ms 600_000
  @default_read_timeout_ms 30_000

  @type session :: %{
          transport: String.t(),
          session_id: String.t(),
          port: port(),
          command: String.t(),
          args: [String.t()],
          env: map(),
          cwd: Path.t(),
          model: String.t() | nil,
          provider: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          protocol_version: pos_integer(),
          turn_timeout_ms: pos_integer(),
          read_timeout_ms: pos_integer()
        }

  @spec create_session(RuntimeProfile.t(), Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def create_session(%RuntimeProfile{} = profile, workspace, opts \\ []) do
    with {:ok, cwd} <- resolve_cwd(profile, workspace),
         {:ok, command} <- resolve_command(profile, cwd),
         {:ok, env} <- normalize_env(profile.env),
         {:ok, port} <- start_port(command, profile.args || [], env, cwd, profile.name) do
      try do
        with {:ok, initialize_response} <- handshake(profile, port),
             {:ok, session_id} <- new_session(profile, port, cwd) do
          {:ok,
           %{
             transport: "stdio",
             session_id: session_id,
             port: port,
             command: command,
             args: profile.args || [],
             env: env,
             cwd: cwd,
             model: profile.model,
             provider: profile.provider,
             workspace: workspace,
             worker_host: Keyword.get(opts, :worker_host),
             protocol_version: Map.get(initialize_response, "protocolVersion", @protocol_version),
             turn_timeout_ms: profile.turn_timeout_ms || @default_turn_timeout_ms,
             read_timeout_ms: profile.read_timeout_ms || @default_read_timeout_ms
           }}
        else
          {:error, reason} ->
            stop_session(%{port: port})
            {:error, reason}
        end
      catch
        kind, reason ->
          stop_session(%{port: port})
          {:error, {:acp_startup_error, profile.name, {:port_crash, kind, reason}}}
      end
    end
  end

  @spec execute_turn(session(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute_turn(%{transport: "stdio", port: port, session_id: session_id} = session, prompt, opts \\ []) do
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)

    send_request(port, @session_prompt_id, "session/prompt", %{
      "sessionId" => session_id,
      "prompt" => [%{"type" => "text", "text" => prompt}]
    })

    case await_response(port, @session_prompt_id, session.turn_timeout_ms, on_event, []) do
      {:ok, response, chunks} ->
        on_event.(%{type: :turn_completed, turn_id: to_string(@session_prompt_id), detail: response})

        {:ok,
         %{
           turn_id: to_string(@session_prompt_id),
           session_id: session_id,
           result: format_prompt_result(response, chunks),
           input_tokens: 0,
           output_tokens: 0
         }}

      {:error, _} = error ->
        error
    end
  end

  @spec cancel_session(session()) :: :ok
  def cancel_session(%{transport: "stdio", port: port, session_id: session_id}) do
    send_notification(port, "session/cancel", %{"sessionId" => session_id})
    :ok
  end

  @spec stop_session(map()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  catch
    :error, _ -> :ok
  end

  def stop_session(_session), do: :ok

  defp handshake(profile, port) do
    send_request(port, @initialize_id, "initialize", %{
      "protocolVersion" => @protocol_version,
      "clientInfo" => %{
        "name" => "symphony",
        "version" => Application.spec(:symphony_elixir, :vsn) |> to_string()
      },
      "clientCapabilities" => %{
        "fs" => %{"readTextFile" => false, "writeTextFile" => false},
        "terminal" => false
      }
    })

    case await_response(port, @initialize_id, profile.read_timeout_ms || @default_read_timeout_ms, fn _ -> :ok end, []) do
      {:ok, response, _events} -> {:ok, response}
      {:error, reason} -> {:error, {:acp_handshake_error, profile.name, :initialize, reason}}
    end
  end

  defp new_session(profile, port, cwd) do
    send_request(port, @session_new_id, "session/new", %{
      "cwd" => cwd,
      "mcpServers" => []
    })

    case await_response(port, @session_new_id, profile.read_timeout_ms || @default_read_timeout_ms, fn _ -> :ok end, []) do
      {:ok, %{"sessionId" => session_id}, _events} when is_binary(session_id) ->
        {:ok, session_id}

      {:ok, response, _events} ->
        {:error, {:acp_handshake_error, profile.name, :session_new, {:unexpected_response, response}}}

      {:error, reason} ->
        {:error, {:acp_handshake_error, profile.name, :session_new, reason}}
    end
  end

  defp await_response(port, expected_id, timeout_ms, on_event, chunks) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        chunk
        |> to_string()
        |> handle_line(port, expected_id, timeout_ms, on_event, chunks)

      {^port, {:data, {:noeol, chunk}}} ->
        chunk
        |> to_string()
        |> handle_line(port, expected_id, timeout_ms, on_event, chunks)

      {^port, {:exit_status, status}} ->
        {:error, {:acp_stdio_exit, status}}
    after
      timeout_ms ->
        {:error, {:acp_stdio_timeout, timeout_ms}}
    end
  end

  defp handle_line("", port, expected_id, timeout_ms, on_event, chunks) do
    await_response(port, expected_id, timeout_ms, on_event, chunks)
  end

  defp handle_line(line, port, expected_id, timeout_ms, on_event, chunks) do
    case Jason.decode(line) do
      {:ok, %{"id" => ^expected_id, "result" => result}} ->
        {:ok, result, Enum.reverse(chunks)}

      {:ok, %{"id" => ^expected_id, "error" => error}} ->
        {:error, {:acp_jsonrpc_error, expected_id, error}}

      {:ok, %{"id" => id, "method" => method}} when not is_nil(id) and is_binary(method) ->
        respond_method_not_found(port, id, method)
        await_response(port, expected_id, timeout_ms, on_event, chunks)

      {:ok, %{"method" => "session/update", "params" => params} = notification} ->
        on_event.(%{type: :session_update, detail: params, raw: notification})
        await_response(port, expected_id, timeout_ms, on_event, maybe_collect_chunk(params, chunks))

      {:ok, %{"method" => method, "params" => params} = notification} when is_binary(method) ->
        on_event.(%{type: :notification, method: method, detail: params, raw: notification})
        await_response(port, expected_id, timeout_ms, on_event, chunks)

      {:ok, payload} ->
        Logger.debug("Ignoring ACP stdio payload while waiting for #{expected_id}: #{inspect(payload)}")
        await_response(port, expected_id, timeout_ms, on_event, chunks)

      {:error, error} ->
        {:error, {:acp_malformed_json, line, Exception.message(error)}}
    end
  end

  defp maybe_collect_chunk(%{"update" => %{"sessionUpdate" => "agent_message_chunk", "content" => content}}, chunks) do
    [content | chunks]
  end

  defp maybe_collect_chunk(_params, chunks), do: chunks

  defp format_prompt_result(response, []), do: response

  defp format_prompt_result(response, chunks) do
    Map.put(response, "content", Enum.map(chunks, &content_text/1) |> Enum.join(""))
  end

  defp content_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp content_text(%{"content" => %{"type" => "text", "text" => text}}) when is_binary(text), do: text
  defp content_text(_content), do: ""

  defp send_request(port, id, method, params) do
    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  defp send_notification(port, method, params) do
    send_message(port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  defp respond_method_not_found(port, id, method) do
    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32601,
        "message" => "ACP client method #{method} is not supported by Symphony"
      }
    })
  end

  defp send_message(port, message) do
    Port.command(port, Jason.encode!(message) <> "\n")
  end

  defp start_port(command, args, env, cwd, profile_name) do
    try do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(command)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(args, &String.to_charlist/1),
            env: Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end),
            cd: String.to_charlist(cwd),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    rescue
      error -> {:error, {:acp_startup_error, profile_name, {:spawn_failed, Exception.message(error)}}}
    end
  end

  defp resolve_command(%RuntimeProfile{name: name, command: command}, cwd) when is_binary(command) do
    command = String.trim(command)

    cond do
      command == "" ->
        {:error, {:acp_config_error, name, :missing_command}}

      String.contains?(command, "/") ->
        validate_executable_path(name, Path.expand(command, cwd))

      executable = System.find_executable(command) ->
        {:ok, executable}

      true ->
        {:error, {:acp_config_error, name, {:missing_command, command}}}
    end
  end

  defp resolve_command(%RuntimeProfile{name: name}, _cwd), do: {:error, {:acp_config_error, name, :missing_command}}

  defp validate_executable_path(name, command) do
    case File.stat(command) do
      {:ok, %{type: :regular, mode: mode}} when (mode &&& 0o111) != 0 ->
        {:ok, command}

      {:ok, %{type: :regular}} ->
        {:error, {:acp_config_error, name, {:non_executable_command, command}}}

      {:ok, _stat} ->
        {:error, {:acp_config_error, name, {:non_executable_command, command}}}

      {:error, _reason} ->
        {:error, {:acp_config_error, name, {:missing_command, command}}}
    end
  end

  defp resolve_cwd(%RuntimeProfile{name: name, cwd: cwd}, workspace) do
    cwd =
      case cwd do
        value when is_binary(value) and value != "" -> Path.expand(value)
        _ -> Path.expand(workspace)
      end

    if File.dir?(cwd), do: {:ok, cwd}, else: {:error, {:acp_config_error, name, {:invalid_cwd, cwd}}}
  end

  defp normalize_env(env) when is_map(env) do
    env =
      Map.new(env, fn {key, value} ->
        {to_string(key), to_string(value)}
      end)

    {:ok, env}
  end

  defp normalize_env(_env), do: {:ok, %{}}
end
