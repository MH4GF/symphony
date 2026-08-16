defmodule SymphonyElixir.Tracker.GitHub.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.Tracker.GitHub.Client

  defmodule FakeGitHubClient do
    @moduledoc false

    def fetch_candidate_issues, do: {:ok, [%SymphonyElixir.Issue{id: "1", state: "Todo"}]}
    def fetch_issues_by_states(states), do: {:ok, states}
    def fetch_issue_states_by_ids(ids), do: {:ok, ids}

    def create_comment(issue_id, body) do
      send(recipient(), {:comment, issue_id, body})
      :ok
    end

    def update_issue_state(issue_id, state_name) do
      send(recipient(), {:state, issue_id, state_name})
      :ok
    end

    defp recipient, do: Application.get_env(:symphony_elixir, :fake_github_recipient)
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :github_client_module)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :github_client_module)
        module -> Application.put_env(:symphony_elixir, :github_client_module, module)
      end

      Application.delete_env(:symphony_elixir, :fake_github_recipient)
    end)

    :ok
  end

  defp write_github_workflow!(overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "github",
          tracker_repo: "MH4GF/works",
          tracker_token: "gh-token",
          tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
          tracker_terminal_states: ["Done", "Canceled"]
        ],
        overrides
      )
    )
  end

  test "tracker resolves the github adapter and delegates every callback" do
    write_github_workflow!()
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :fake_github_recipient, self())

    assert Config.settings!().tracker.kind == "github"
    assert Tracker.adapter() == GitHubAdapter

    assert {:ok, [%SymphonyElixir.Issue{id: "1"}]} = Tracker.fetch_candidate_issues()
    assert {:ok, ["Done"]} = Tracker.fetch_issues_by_states(["Done"])
    assert {:ok, ["7"]} = Tracker.fetch_issue_states_by_ids(["7"])

    assert :ok = Tracker.create_comment("7", "workpad")
    assert_received {:comment, "7", "workpad"}

    assert :ok = Tracker.update_issue_state("7", "Human Review")
    assert_received {:state, "7", "Human Review"}
  end

  test "github tracker defaults to the github api endpoint" do
    write_github_workflow!()

    assert Config.settings!().tracker.endpoint == "https://api.github.com"
  end

  test "github tracker keeps an explicitly configured endpoint" do
    write_github_workflow!(tracker_endpoint: "https://github.example.test/api/v3")

    assert Config.settings!().tracker.endpoint == "https://github.example.test/api/v3"
  end

  test "github tracker requires an owner/name repo" do
    write_github_workflow!(tracker_repo: nil)
    assert {:error, :missing_github_repo} = Config.validate!()

    write_github_workflow!(tracker_repo: "works")
    assert {:error, :missing_github_repo} = Config.validate!()

    write_github_workflow!()
    assert :ok = Config.validate!()
  end

  test "linear tracker is unaffected by the github fields" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    assert Config.settings!().tracker.endpoint == "https://api.linear.app/graphql"
    assert :ok = Config.validate!()
    assert Tracker.adapter() == SymphonyElixir.Linear.Adapter
  end

  test "an unsupported tracker kind is rejected instead of falling back to linear" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")

    assert {:error, {:unsupported_tracker_kind, "jira"}} = Config.validate!()
    assert_raise ArgumentError, fn -> Tracker.adapter() end
  end

  test "known states put the configured active states first" do
    write_github_workflow!()

    known = Client.known_states()

    assert Enum.take(known, 4) == ["Todo", "In Progress", "Merging", "Rework"]
    assert "Done" in known
    assert "Canceled" in known
    assert "Backlog" in known
    assert known == Enum.uniq(known)
  end
end
