defmodule SymphonyElixir.GitHub.StatusLabelsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.StatusLabels

  test "maps a state name onto a status label and back" do
    assert StatusLabels.status_label("In Progress") == "status:in-progress"

    assert StatusLabels.state_from_labels(
             ["status:in-progress", "area:api"],
             ["Todo", "In Progress"]
           ) == "In Progress"
  end

  test "known_states order decides which status label wins" do
    assert StatusLabels.state_from_labels(["status:done", "status:todo"], ["Todo", "Done"]) == "Todo"
  end

  test "an unconfigured status label reads back as a deslugged state" do
    assert StatusLabels.state_from_labels(["status:human-review"], ["Todo"]) == "Human Review"
  end

  test "labels without a status entry resolve to nil" do
    assert StatusLabels.state_from_labels(["bug"], ["Todo"]) == nil
  end

  test "resolve_state prefers closed state_reason over labels" do
    payload = %{"state" => "closed", "state_reason" => "not_planned"}
    assert StatusLabels.resolve_state(payload, ["status:todo"], ["Todo"]) == "Canceled"

    assert StatusLabels.resolve_state(%{"state" => "closed"}, [], ["Todo"]) == "Done"
  end

  test "an open issue without a status label falls back to the default open state" do
    assert StatusLabels.resolve_state(%{"state" => "open"}, [], ["Todo"]) == "Backlog"
  end

  test "apply_status_label replaces every existing status label" do
    assert StatusLabels.apply_status_label(["status:todo", "bug"], "In Progress") ==
             ["bug", "status:in-progress"]

    assert StatusLabels.apply_status_label(["status:todo", "bug"], nil) == ["bug"]
  end

  test "terminal_state? covers the two closed states only" do
    assert StatusLabels.terminal_state?("Done")
    assert StatusLabels.terminal_state?("Canceled")
    refute StatusLabels.terminal_state?("In Progress")
    refute StatusLabels.terminal_state?(nil)
  end

  test "priority labels resolve to 1..4 and ignore anything else" do
    assert StatusLabels.priority_from_labels(["priority:2"]) == 2
    assert StatusLabels.priority_from_labels(["PRIORITY:4"]) == 4
    assert StatusLabels.priority_from_labels(["priority:9", "bug"]) == nil
    assert StatusLabels.priority_from_labels([]) == nil
  end

  test "known_states collects tracker and review watch states with the default open state" do
    settings = %{
      tracker: %{active_states: ["Todo", "In Progress"], terminal_states: ["Done"]},
      review_watch: %{states: ["Human Review"], on_conflict_state: "In Progress"}
    }

    assert StatusLabels.known_states(settings) == [
             "Todo",
             "In Progress",
             "Done",
             "Human Review",
             "Backlog"
           ]
  end

  test "known_states tolerates a missing review watch section and blank entries" do
    settings = %{tracker: %{active_states: ["Todo", ""], terminal_states: nil}}

    assert StatusLabels.known_states(settings) == ["Todo", "Backlog"]
  end
end
