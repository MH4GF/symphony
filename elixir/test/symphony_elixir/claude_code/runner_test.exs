defmodule SymphonyElixir.ClaudeCode.RunnerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ClaudeCode.Runner

  describe "parse_short/1" do
    test "parses plain short id" do
      assert {:ok, "239007b1"} = Runner.parse_short("backgrounded · 239007b1\n")
    end

    test "parses ANSI-colored short id" do
      out = "backgrounded · \e[36m239007b1\e[39m\n"
      assert {:ok, "239007b1"} = Runner.parse_short(out)
    end

    test "detects --bg disabled" do
      assert {:error, :bg_disabled} = Runner.parse_short("error: '--bg' is not enabled\n")
    end

    test "returns no_short when absent" do
      assert {:error, {:no_short, _}} = Runner.parse_short("something unexpected\n")
    end
  end

  describe "interpret_state/1" do
    test "done with result and sessionId" do
      raw = ~s({"state":"done","sessionId":"sess-1","output":{"result":"ok"}})
      assert {:done, "ok", "sess-1"} = Runner.interpret_state(raw)
    end

    test "failed prefers detail" do
      raw = ~s({"state":"failed","detail":"boom","output":{"result":"r"}})
      assert {:failed, "boom", _} = Runner.interpret_state(raw)
    end

    test "failed falls back to result then default" do
      assert {:failed, "r", _} = Runner.interpret_state(~s({"state":"failed","output":{"result":"r"}}))

      assert {:failed, "bg session reported state=failed", _} =
               Runner.interpret_state(~s({"state":"failed"}))
    end

    test "working for other states" do
      assert {:working, "sess-2"} =
               Runner.interpret_state(~s({"state":"working","sessionId":"sess-2"}))
    end

    test "malformed payload is treated as working" do
      assert {:working, nil} = Runner.interpret_state("not json")
    end
  end

  describe "build_args/3" do
    test "first turn has no resume" do
      settings = %{codex: %{command: "claude"}}
      assert Runner.build_args("hi", nil, settings) == ["--bg", "hi"]
    end

    test "continuation adds --resume" do
      settings = %{codex: %{command: "claude"}}
      assert Runner.build_args("more", "sess-1", settings) == ["--bg", "--resume", "sess-1", "more"]
    end

    test "includes claude_args" do
      settings = %{codex: %{command: "claude", claude_args: ["--permission-mode", "plan"]}}
      assert Runner.build_args("hi", nil, settings) == ["--bg", "--permission-mode", "plan", "hi"]
    end
  end

  describe "run_turn/4 (injected runner + reader)" do
    setup do
      settings = %{codex: %{command: "claude", turn_timeout_ms: 5_000, stall_timeout_ms: 0, claude_args: []}}
      {:ok, session} = Runner.start_session("/tmp/symphony-runner-test")
      on_exit(fn -> if Process.alive?(session.holder), do: Agent.stop(session.holder) end)
      %{settings: settings, session: session}
    end

    test "done returns ok with session_id and result", %{settings: settings, session: session} do
      test_pid = self()

      runner = fn args, _ws ->
        send(test_pid, {:args, args})
        {"backgrounded · aaaa0001\n", 0}
      end

      reader = fn _short -> {:ok, ~s({"state":"done","sessionId":"sess-x","output":{"result":"done!"}})} end

      assert {:ok, %{session_id: "sess-x", result: "done!", short: "aaaa0001"}} =
               Runner.run_turn(session, "do it", %{id: "1", identifier: "T-1"},
                 settings: settings,
                 command_runner: runner,
                 state_reader: reader,
                 sleep_fn: fn _ -> :ok end
               )

      assert_received {:args, ["--bg", "do it"]}
    end

    test "failed returns error", %{settings: settings, session: session} do
      runner = fn _args, _ws -> {"backgrounded · aaaa0002\n", 0} end
      reader = fn _short -> {:ok, ~s({"state":"failed","detail":"nope"})} end

      assert {:error, {:bg_failed, "nope"}} =
               Runner.run_turn(session, "do it", %{id: "1", identifier: "T-1"},
                 settings: settings,
                 command_runner: runner,
                 state_reader: reader,
                 sleep_fn: fn _ -> :ok end
               )
    end

    test "bg disabled returns error", %{settings: settings, session: session} do
      runner = fn _args, _ws -> {"'--bg' is not enabled\n", 1} end
      reader = fn _short -> {:error, :enoent} end

      assert {:error, :bg_disabled} =
               Runner.run_turn(session, "do it", %{id: "1", identifier: "T-1"},
                 settings: settings,
                 command_runner: runner,
                 state_reader: reader,
                 sleep_fn: fn _ -> :ok end
               )
    end

    test "continuation reuses captured session_id via --resume", %{settings: settings, session: session} do
      test_pid = self()

      runner = fn args, _ws ->
        send(test_pid, {:args, args})
        {"backgrounded · aaaa0003\n", 0}
      end

      reader = fn _short -> {:ok, ~s({"state":"done","sessionId":"sess-keep","output":{"result":"r"}})} end
      opts = [settings: settings, command_runner: runner, state_reader: reader, sleep_fn: fn _ -> :ok end]

      assert {:ok, _} = Runner.run_turn(session, "turn1", %{id: "1", identifier: "T-1"}, opts)
      assert_received {:args, ["--bg", "turn1"]}

      assert {:ok, _} = Runner.run_turn(session, "turn2", %{id: "1", identifier: "T-1"}, opts)
      assert_received {:args, ["--bg", "--resume", "sess-keep", "turn2"]}
    end
  end
end
