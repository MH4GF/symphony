defmodule SymphonyElixir.ClaudeCode.Runner do
  @moduledoc """
  Agent runner backed by `claude --bg`.

  Drop-in replacement for `SymphonyElixir.Codex.AppServer`: same
  `start_session/2`, `run_turn/4`, `stop_session/1` contract so `AgentRunner`
  only swaps the alias.

  Before each launch the workspace is recorded as trusted in Claude's config
  (see `SymphonyElixir.ClaudeCode.WorkspaceTrust`); without that, `claude --bg`
  refuses to start in a fresh clone.

  A bg session has no long-lived stdio process. Each turn launches
  `claude --bg "<prompt>"` in the workspace, captures the daemon short id, and
  polls `~/.claude/jobs/<short>/state.json` until the session reaches a
  terminal state. The claude session id (used for `--resume` continuation) is
  held in a small Agent so it survives across turns within one run.

  Pattern referenced from `MH4GF/tq` `dispatch/bg.go` and `dispatch/queue_worker.go`.
  """

  require Logger
  alias SymphonyElixir.ClaudeCode.WorkspaceTrust
  alias SymphonyElixir.Config

  @bg_short_re ~r/^backgrounded · ([a-f0-9]{8})\b/m
  @bg_disabled_marker "'--bg' is not enabled"
  @ansi_re ~r/\x1b\[[0-9;]*m/
  @state_done "done"
  @state_failed "failed"
  @default_poll_interval_ms 2_000

  @type session :: %{
          holder: pid(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          metadata: map()
        }

  @doc """
  Convenience that mirrors `AppServer.run/4`: start, one turn, stop.
  """
  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    worker_host = Keyword.get(opts, :worker_host)
    expanded = Path.expand(workspace)
    {:ok, holder} = Agent.start_link(fn -> %{session_id: nil, short: nil} end)

    {:ok,
     %{
       holder: holder,
       workspace: expanded,
       worker_host: worker_host,
       metadata: %{worker_host: worker_host}
     }}
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{holder: holder, workspace: workspace} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    runner = Keyword.get(opts, :command_runner, &default_command_runner/2)
    state_reader = Keyword.get(opts, :state_reader, &default_state_reader/1)
    sleep_fn = Keyword.get(opts, :sleep_fn, &Process.sleep/1)
    settings = Keyword.get(opts, :settings, Config.settings!())

    trust = Keyword.get(opts, :workspace_trust, &WorkspaceTrust.ensure_trusted/1)

    prior_session_id = Agent.get(holder, & &1.session_id)
    args = build_args(prompt, prior_session_id, settings)

    ensure_workspace_trusted(trust, workspace, issue)

    case launch(runner, args, workspace) do
      {:ok, short} ->
        Agent.update(holder, &Map.put(&1, :short, short))
        emit(on_message, :session_started, %{short: short}, session)
        poll(session, short, issue, on_message, state_reader, sleep_fn, settings)

      {:error, reason} ->
        Logger.error("claude --bg launch failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit(on_message, :startup_failed, %{reason: reason}, session)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{holder: holder}) do
    short = Agent.get(holder, &Map.get(&1, :short))
    if is_binary(short), do: stop_bg_session(short)
    Agent.stop(holder)
    :ok
  end

  # --- launch -----------------------------------------------------------------

  # `claude --bg` (>= 2.1.280) exits when the workspace has not accepted the
  # trust prompt. Persist trust for the clone first; a seeding failure is
  # logged but does not block the launch, so the real `claude` error surfaces.
  defp ensure_workspace_trusted(trust, workspace, issue) do
    case trust.(workspace) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("workspace trust seeding failed for #{issue_context(issue)} workspace=#{workspace}: #{inspect(reason)}")

        :ok
    end
  end

  defp launch(runner, args, workspace) do
    {output, _status} = runner.(args, workspace)
    parse_short(output)
  end

  @doc """
  Parse the daemon short id from `claude --bg` output. ANSI color codes are
  stripped first so a colorized banner still matches.
  """
  @spec parse_short(binary()) :: {:ok, String.t()} | {:error, :bg_disabled | {:no_short, binary()}}
  def parse_short(output) when is_binary(output) do
    stripped = strip_ansi(output)

    cond do
      String.contains?(stripped, @bg_disabled_marker) ->
        {:error, :bg_disabled}

      match = Regex.run(@bg_short_re, stripped) ->
        {:ok, Enum.at(match, 1)}

      true ->
        {:error, {:no_short, truncate(stripped, 2_000)}}
    end
  end

  defp strip_ansi(s), do: Regex.replace(@ansi_re, s, "")

  @doc false
  @spec build_args(String.t(), String.t() | nil, struct()) :: [String.t()]
  def build_args(prompt, prior_session_id, settings) do
    base = command_args(settings)
    resume = resume_args(prior_session_id)
    extra = Map.get(settings.codex, :claude_args, [])
    base ++ ["--bg"] ++ resume ++ extra ++ [prompt]
  end

  defp resume_args(session_id) when is_binary(session_id) and session_id != "",
    do: ["--resume", session_id]

  defp resume_args(_), do: []

  # `codex.command` is reused as the agent command (default "codex app-server").
  # A Claude workflow sets `codex.command: claude`. Drop a leading "claude"
  # executable token and keep any extra base flags.
  defp command_args(settings) do
    case String.split(String.trim(to_string(settings.codex.command)), ~r/\s+/, trim: true) do
      ["claude" | rest] -> rest
      [_other | rest] -> rest
      [] -> []
    end
  end

  # --- poll -------------------------------------------------------------------

  # Poll context bundles the per-turn loop state so the recursive helpers stay
  # low-arity (credo FunctionArity).
  defp poll(session, short, issue, on_message, state_reader, sleep_fn, settings) do
    ctx = %{
      session: session,
      short: short,
      issue: issue,
      on_message: on_message,
      state_reader: state_reader,
      sleep_fn: sleep_fn,
      deadline: monotonic_ms() + turn_timeout_ms(settings),
      stall_ms: stall_timeout_ms(settings)
    }

    do_poll(ctx, monotonic_ms())
  end

  defp do_poll(ctx, last_progress) do
    now = monotonic_ms()

    cond do
      now >= ctx.deadline ->
        {:error, {:turn_timeout, ctx.short}}

      ctx.stall_ms > 0 and now - last_progress >= ctx.stall_ms ->
        {:error, {:stalled, ctx.short}}

      true ->
        case ctx.state_reader.(ctx.short) do
          {:ok, raw} ->
            handle_state(ctx, raw)

          {:error, :enoent} ->
            ctx.sleep_fn.(@default_poll_interval_ms)
            do_poll(ctx, last_progress)

          {:error, reason} ->
            Logger.warning("claude bg state read failed short=#{ctx.short}: #{inspect(reason)}")
            ctx.sleep_fn.(@default_poll_interval_ms)
            do_poll(ctx, last_progress)
        end
    end
  end

  defp handle_state(ctx, raw) do
    %{holder: holder} = ctx.session

    case interpret_state(raw) do
      {:done, result, session_id} ->
        maybe_store_session_id(holder, session_id)
        sid = session_id || Agent.get(holder, & &1.session_id)
        Logger.info("claude bg turn done for #{issue_context(ctx.issue)} short=#{ctx.short} session_id=#{sid}")
        emit(ctx.on_message, :turn_completed, %{short: ctx.short, session_id: sid}, ctx.session)
        {:ok, %{result: result, session_id: sid, short: ctx.short}}

      {:failed, detail, session_id} ->
        maybe_store_session_id(holder, session_id)
        emit(ctx.on_message, :turn_failed, %{short: ctx.short, reason: detail}, ctx.session)
        {:error, {:bg_failed, detail}}

      {:working, session_id} ->
        maybe_store_session_id(holder, session_id)
        emit(ctx.on_message, :working, %{short: ctx.short}, ctx.session)
        ctx.sleep_fn.(@default_poll_interval_ms)
        do_poll(ctx, monotonic_ms())
    end
  end

  @doc """
  Interpret a `~/.claude/jobs/<short>/state.json` payload.

  Returns `{:done, result, session_id}`, `{:failed, detail, session_id}`, or
  `{:working, session_id}`. Unknown / malformed payloads are treated as
  `:working` so the poll loop keeps waiting until timeout.
  """
  @spec interpret_state(binary()) ::
          {:done, String.t(), String.t() | nil}
          | {:failed, String.t(), String.t() | nil}
          | {:working, String.t() | nil}
  def interpret_state(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) ->
        session_id = blank_to_nil(map["sessionId"])
        result = get_in(map, ["output", "result"]) || ""

        case map["state"] do
          @state_done -> {:done, result, session_id}
          @state_failed -> {:failed, failure_detail(map, result), session_id}
          _ -> {:working, session_id}
        end

      _ ->
        {:working, nil}
    end
  end

  defp failure_detail(map, result) do
    [map["detail"], result, "bg session reported state=failed"]
    |> Enum.map(&blank_to_nil/1)
    |> Enum.find("bg session reported state=failed", &is_binary/1)
  end

  defp maybe_store_session_id(holder, session_id) when is_binary(session_id) do
    Agent.update(holder, fn s ->
      if s.session_id in [nil, ""], do: %{s | session_id: session_id}, else: s
    end)
  end

  defp maybe_store_session_id(_holder, _session_id), do: :ok

  # --- defaults / helpers -----------------------------------------------------

  defp default_command_runner(args, workspace) do
    System.cmd("claude", args, cd: workspace, env: filtered_env(), stderr_to_stdout: true)
  rescue
    e -> {Exception.message(e), 1}
  end

  # Drop CLAUDECODE so the spawned claude does not treat itself as nested.
  defp filtered_env, do: [{"CLAUDECODE", nil}]

  defp default_state_reader(short) do
    path = Path.join([System.user_home!(), ".claude", "jobs", short, "state.json"])

    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_bg_session(short) do
    System.cmd("claude", ["stop", short], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp turn_timeout_ms(settings), do: settings.codex.turn_timeout_ms
  defp stall_timeout_ms(settings), do: settings.codex.stall_timeout_ms

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp emit(on_message, event, payload, session) do
    on_message.(Map.merge(payload, %{event: event, timestamp: DateTime.utc_now(), metadata: session.metadata}))
    :ok
  end

  defp default_on_message(_message), do: :ok

  defp blank_to_nil(v) when is_binary(v) do
    if String.trim(v) == "", do: nil, else: v
  end

  defp blank_to_nil(_), do: nil

  defp truncate(s, max) when is_binary(s) do
    if String.length(s) <= max, do: s, else: String.slice(s, 0, max)
  end

  defp issue_context(%{id: id, identifier: identifier}), do: "issue_id=#{id} issue_identifier=#{identifier}"
  defp issue_context(_), do: "issue=unknown"
end
