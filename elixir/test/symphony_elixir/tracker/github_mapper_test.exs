defmodule SymphonyElixir.Tracker.GitHub.MapperTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Issue
  alias SymphonyElixir.Tracker.GitHub.Mapper

  @known_states [
    "Todo",
    "In Progress",
    "Merging",
    "Rework",
    "Done",
    "Canceled",
    "Human Review",
    "Backlog"
  ]

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 123,
        "title" => "Add GitHub tracker",
        "body" => "spec body",
        "state" => "open",
        "html_url" => "https://github.com/MH4GF/works/issues/123",
        "labels" => [%{"name" => "status:todo"}],
        "assignee" => %{"login" => "MH4GF"},
        "created_at" => "2026-08-16T01:02:03Z",
        "updated_at" => "2026-08-16T04:05:06Z"
      },
      overrides
    )
  end

  describe "normalize/2" do
    test "maps an open issue carrying a status label" do
      assert %Issue{} = issue = Mapper.normalize(payload(), @known_states)

      assert issue.id == "123"
      assert issue.identifier == "#123"
      assert issue.title == "Add GitHub tracker"
      assert issue.description == "spec body"
      assert issue.state == "Todo"
      assert issue.branch_name == "symphony/123-add-github-tracker"
      assert issue.url == "https://github.com/MH4GF/works/issues/123"
      assert issue.assignee_id == "MH4GF"
      assert issue.labels == ["status:todo"]
      assert issue.priority == nil
      assert issue.blocked_by == []
      assert issue.assigned_to_worker == true
      assert %DateTime{} = issue.created_at
      assert %DateTime{} = issue.updated_at
    end

    test "treats an open issue without a status label as backlog" do
      issue = Mapper.normalize(payload(%{"labels" => []}), @known_states)

      assert issue.state == "Backlog"
    end

    test "maps a closed issue to the completed terminal state" do
      issue = Mapper.normalize(payload(%{"state" => "closed", "state_reason" => "completed"}), @known_states)

      assert issue.state == "Done"
    end

    test "maps a closed not_planned issue to the canceled terminal state" do
      issue = Mapper.normalize(payload(%{"state" => "closed", "state_reason" => "not_planned"}), @known_states)

      assert issue.state == "Canceled"
    end

    test "maps a closed issue without a reason to the completed terminal state" do
      issue = Mapper.normalize(payload(%{"state" => "closed"}), @known_states)

      assert issue.state == "Done"
    end

    test "ignores pull requests returned by the issues endpoint" do
      assert Mapper.normalize(payload(%{"pull_request" => %{"url" => "https://example.test"}}), @known_states) == nil
    end

    test "ignores payloads without an issue number" do
      assert Mapper.normalize(payload(%{"number" => nil}), @known_states) == nil
    end

    test "resolves conflicting status labels by known state order" do
      labels = [%{"name" => "status:rework"}, %{"name" => "status:todo"}]

      issue = Mapper.normalize(payload(%{"labels" => labels}), @known_states)

      assert issue.state == "Todo"
    end

    test "reads an unconfigured status label back as a state name" do
      issue = Mapper.normalize(payload(%{"labels" => [%{"name" => "status:on-hold"}]}), @known_states)

      assert issue.state == "On Hold"
    end

    test "reads priority from a priority label" do
      labels = [%{"name" => "status:todo"}, %{"name" => "priority:2"}]

      issue = Mapper.normalize(payload(%{"labels" => labels}), @known_states)

      assert issue.priority == 2
    end

    test "ignores priority labels outside the supported range" do
      labels = [%{"name" => "priority:9"}, %{"name" => "priority:high"}]

      issue = Mapper.normalize(payload(%{"labels" => labels}), @known_states)

      assert issue.priority == nil
    end
  end

  describe "status_label/1" do
    test "slugifies multi word state names" do
      assert Mapper.status_label("In Progress") == "status:in-progress"
      assert Mapper.status_label("Human Review") == "status:human-review"
      assert Mapper.status_label("Todo") == "status:todo"
    end
  end

  describe "apply_status_label/2" do
    test "replaces every existing status label while keeping the rest" do
      current = ["area:infra", "status:todo", "priority:2", "status:rework"]

      assert Mapper.apply_status_label(current, "Human Review") == [
               "area:infra",
               "priority:2",
               "status:human-review"
             ]
    end

    test "strips status labels when moving to a terminal state" do
      assert Mapper.apply_status_label(["status:merging", "area:infra"], nil) == ["area:infra"]
    end
  end

  describe "terminal_state?/1" do
    test "recognizes the closed states" do
      assert Mapper.terminal_state?("Done")
      assert Mapper.terminal_state?("Canceled")
      refute Mapper.terminal_state?("Merging")
      refute Mapper.terminal_state?("Backlog")
    end
  end

  describe "branch_name/2" do
    test "falls back to the number when the title has no usable characters" do
      assert Mapper.branch_name(7, "***") == "symphony/7"
      assert Mapper.branch_name(7, nil) == "symphony/7"
    end

    test "slugifies the title" do
      assert Mapper.branch_name(7, "Fix  the CI!") == "symphony/7-fix-the-ci"
    end
  end
end
