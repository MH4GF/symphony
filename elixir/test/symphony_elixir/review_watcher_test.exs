defmodule SymphonyElixir.ReviewWatcherTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ReviewWatcher

  defmodule FakeWrites do
    @moduledoc false

    @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
    def create_comment(issue_id, body) do
      notify({:writes_comment, issue_id, body})
    end

    @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
    def update_issue_state(issue_id, state_name) do
      notify({:writes_state_update, issue_id, state_name})
    end

    defp notify(message) do
      case Application.get_env(:symphony_elixir, :fake_github_recipient) do
        pid when is_pid(pid) -> send(pid, message)
        _recipient -> :ok
      end

      :ok
    end
  end

  defmodule FailingClient do
    @moduledoc false

    @spec fetch_issues_by_states([String.t()]) :: {:error, term()}
    def fetch_issues_by_states(_states), do: {:error, :github_read_rejected}

    @spec fetch_issues_by_ids([String.t()]) :: {:error, term()}
    def fetch_issues_by_ids(_ids), do: {:error, :github_read_rejected}
  end

  defmodule FailingWrites do
    @moduledoc false

    @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
    def create_comment(_issue_id, _body), do: {:error, :github_write_rejected}

    @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
    def update_issue_state(_issue_id, _state_name), do: {:error, :github_write_rejected}
  end

  defmodule FakeGitHub do
    @moduledoc false

    @spec pull_request_for_workspace(Path.t(), timeout()) :: {:ok, map()} | {:error, term()}
    def pull_request_for_workspace(workspace, _timeout_ms) do
      case Application.get_env(:symphony_elixir, :fake_github_recipient) do
        pid when is_pid(pid) -> send(pid, {:fake_github_called, workspace})
        _recipient -> :ok
      end

      Application.get_env(:symphony_elixir, :fake_github_result, {:error, :no_pull_request})
    end
  end

  setup do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-review-watch-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)

    Application.put_env(:symphony_elixir, :github_module, FakeGitHub)
    Application.put_env(:symphony_elixir, :github_writes_module, FakeWrites)
    Application.put_env(:symphony_elixir, :fake_github_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_module)
      Application.delete_env(:symphony_elixir, :github_writes_module)
      Application.delete_env(:symphony_elixir, :fake_github_recipient)
      Application.delete_env(:symphony_elixir, :fake_github_result)
      File.rm_rf(workspace_root)
    end)

    %{workspace_root: workspace_root}
  end

  test "returns a conflicting review issue to the configured active state", %{workspace_root: workspace_root} do
    configure_review_watch(workspace_root)
    workspace = create_workspace!(workspace_root, "MT-1")
    put_issues([issue("issue-1", "MT-1", ["symphony"])])
    put_pull_request("CONFLICTING")

    ReviewWatcher.scan_for_test(%ReviewWatcher.State{})

    assert_received {:fake_github_called, ^workspace}
    assert_received {:writes_comment, "issue-1", body}
    assert body =~ "https://github.com/acme/repo/pull/7"
    assert_received {:writes_state_update, "issue-1", "In Progress"}
  end

  test "leaves a mergeable review issue alone", %{workspace_root: workspace_root} do
    configure_review_watch(workspace_root)
    create_workspace!(workspace_root, "MT-1")
    put_issues([issue("issue-1", "MT-1", ["symphony"])])
    put_pull_request("MERGEABLE")

    ReviewWatcher.scan_for_test(%ReviewWatcher.State{})

    refute_received {:writes_state_update, _issue_id, _state}
  end

  test "does not return the same head commit twice", %{workspace_root: workspace_root} do
    configure_review_watch(workspace_root)
    create_workspace!(workspace_root, "MT-1")
    put_issues([issue("issue-1", "MT-1", ["symphony"])])
    put_pull_request("CONFLICTING")

    state = ReviewWatcher.scan_for_test(%ReviewWatcher.State{})
    assert_received {:writes_state_update, "issue-1", "In Progress"}

    ReviewWatcher.scan_for_test(state)
    refute_received {:writes_state_update, _issue_id, _state}
  end

  test "returns the issue again once the branch has moved on", %{workspace_root: workspace_root} do
    configure_review_watch(workspace_root)
    create_workspace!(workspace_root, "MT-1")
    put_issues([issue("issue-1", "MT-1", ["symphony"])])
    put_pull_request("CONFLICTING", "sha-1")

    state = ReviewWatcher.scan_for_test(%ReviewWatcher.State{})
    assert_received {:writes_state_update, "issue-1", "In Progress"}

    put_pull_request("CONFLICTING", "sha-2")
    ReviewWatcher.scan_for_test(state)

    assert_received {:writes_state_update, "issue-1", "In Progress"}
  end

  test "skips issues without a required label", %{workspace_root: workspace_root} do
    configure_review_watch(workspace_root)
    create_workspace!(workspace_root, "MT-1")
    put_issues([issue("issue-1", "MT-1", ["other"])])
    put_pull_request("CONFLICTING")

    ReviewWatcher.scan_for_test(%ReviewWatcher.State{})

    refute_received {:fake_github_called, _workspace}
    refute_received {:writes_state_update, _issue_id, _state}
  end

  test "skips issues whose workspace no longer exists", %{workspace_root: workspace_root} do
    configure_review_watch(workspace_root)
    put_issues([issue("issue-1", "MT-1", ["symphony"])])
    put_pull_request("CONFLICTING")

    ReviewWatcher.scan_for_test(%ReviewWatcher.State{})

    refute_received {:fake_github_called, _workspace}
    refute_received {:writes_state_update, _issue_id, _state}
  end

  test "does nothing while review watch is disabled", %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      review_watch_enabled: false
    )

    create_workspace!(workspace_root, "MT-1")
    put_issues([issue("issue-1", "MT-1", ["symphony"])])
    put_pull_request("CONFLICTING")

    ReviewWatcher.scan_for_test(%ReviewWatcher.State{})

    refute_received {:fake_github_called, _workspace}
  end

  test "a tracker read failure skips the tick", %{workspace_root: workspace_root} do
    previous_client = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, FailingClient)

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, previous_client)
      end
    end)

    write_github_workflow!(workspace_root)

    log =
      capture_log(fn ->
        assert %ReviewWatcher.State{} = ReviewWatcher.scan_for_test(%ReviewWatcher.State{})
      end)

    assert log =~ "Review watch scan skipped"
    refute_received {:fake_github_called, _workspace}
  end

  test "a pull request lookup failure leaves the issue alone", %{workspace_root: workspace_root} do
    configure_review_watch(workspace_root)
    workspace = create_workspace!(workspace_root, "MT-1")
    put_issues([issue("issue-1", "MT-1", ["symphony"])])
    Application.put_env(:symphony_elixir, :fake_github_result, {:error, :gh_not_found})

    log =
      capture_log(fn ->
        ReviewWatcher.scan_for_test(%ReviewWatcher.State{})
      end)

    assert_received {:fake_github_called, ^workspace}
    assert log =~ "Review watch pull request lookup skipped"
    refute_received {:writes_state_update, _issue_id, _state}
  end

  test "a failed write leaves the issue for the next tick", %{workspace_root: workspace_root} do
    configure_review_watch(workspace_root)
    create_workspace!(workspace_root, "MT-1")
    put_issues([issue("issue-1", "MT-1", ["symphony"])])
    put_pull_request("CONFLICTING")
    Application.put_env(:symphony_elixir, :github_writes_module, FailingWrites)

    log =
      capture_log(fn ->
        assert %ReviewWatcher.State{returned_head_oids: %{}} =
                 ReviewWatcher.scan_for_test(%ReviewWatcher.State{})
      end)

    assert log =~ "Review watch return failed"
  end

  test "an issue without an identifier is skipped", %{workspace_root: workspace_root} do
    configure_review_watch(workspace_root)
    put_issues([%{issue("issue-1", "MT-1", ["symphony"]) | identifier: nil}])
    put_pull_request("CONFLICTING")

    ReviewWatcher.scan_for_test(%ReviewWatcher.State{})

    refute_received {:fake_github_called, _workspace}
  end

  test "an explicitly disabled review_watch section still validates", %{workspace_root: workspace_root} do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
    workspace:
      root: #{inspect(workspace_root)}
    review_watch:
      enabled: false
      interval_ms: 1000
    ---

    You are working on {{ issue.identifier }}.
    """)

    assert :ok = WorkflowStore.force_reload()
    assert Config.settings!().review_watch.enabled == false
    assert Config.settings!().review_watch.interval_ms == 1000
  end

  test "the watcher scans on each tick and ignores unknown messages", %{workspace_root: workspace_root} do
    configure_review_watch(workspace_root)
    create_workspace!(workspace_root, "MT-1")
    put_issues([issue("issue-1", "MT-1", ["symphony"])])
    put_pull_request("MERGEABLE")

    name = Module.concat(__MODULE__, "Watcher#{System.unique_integer([:positive])}")
    assert {:ok, pid} = ReviewWatcher.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    send(pid, :tick)
    assert %ReviewWatcher.State{} = :sys.get_state(pid)
    assert_received {:fake_github_called, _workspace}

    send(pid, :unexpected_message)
    assert %ReviewWatcher.State{} = :sys.get_state(pid)
  end

  defp configure_review_watch(workspace_root) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["symphony"],
      workspace_root: workspace_root,
      review_watch_enabled: true,
      review_watch_states: ["In Review"],
      review_watch_on_conflict_state: "In Progress"
    )
  end

  defp write_github_workflow!(workspace_root) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: github
      provider:
        repo: "octo/repo"
        token: "test-token"
      active_states: ["Todo", "In Progress"]
      terminal_states: ["Done", "Canceled"]
    workspace:
      root: #{inspect(workspace_root)}
    review_watch:
      enabled: true
      states: ["In Review"]
      on_conflict_state: "In Progress"
    ---

    You are working on {{ issue.identifier }}.
    """)

    if Process.whereis(WorkflowStore) do
      assert :ok = WorkflowStore.force_reload()
    end
  end

  defp create_workspace!(workspace_root, identifier) do
    workspace = Path.join(workspace_root, identifier)
    File.mkdir_p!(workspace)
    {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
    canonical_workspace
  end

  defp issue(id, identifier, labels) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "title",
      state: "In Review",
      labels: labels,
      dispatchable: true
    }
  end

  defp put_issues(issues) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
  end

  defp put_pull_request(mergeable, head_oid \\ "sha-1") do
    Application.put_env(
      :symphony_elixir,
      :fake_github_result,
      {:ok,
       %{
         number: 7,
         url: "https://github.com/acme/repo/pull/7",
         state: "OPEN",
         mergeable: mergeable,
         head_oid: head_oid
       }}
    )
  end
end
