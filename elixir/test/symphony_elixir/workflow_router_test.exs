defmodule SymphonyElixir.WorkflowRouterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.WorkflowRouter

  @code %{name: "code", match_labels: []}
  @life %{name: "life", match_labels: ["life"]}
  @finance %{name: "finance", match_labels: ["finance", "recurring"]}

  describe "select/3" do
    test "routes to the workflow whose single label matches" do
      assert WorkflowRouter.select(["life"], [@finance, @life], @code).name == "life"
    end

    test "requires all match_labels to be present" do
      assert WorkflowRouter.select(["finance"], [@finance, @life], @code).name == "code"
      assert WorkflowRouter.select(["finance", "recurring"], [@finance, @life], @code).name == "finance"
    end

    test "returns the default when no workflow matches" do
      assert WorkflowRouter.select(["misc"], [@finance, @life], @code).name == "code"
      assert WorkflowRouter.select([], [@finance, @life], @code).name == "code"
    end

    test "a workflow with empty match_labels never auto-matches" do
      empty = %{name: "never", match_labels: []}
      assert WorkflowRouter.select(["life"], [empty, @life], @code).name == "life"
    end

    test "first matching workflow wins" do
      a = %{name: "a", match_labels: ["x"]}
      b = %{name: "b", match_labels: ["x"]}
      assert WorkflowRouter.select(["x"], [a, b], @code).name == "a"
    end

    test "matching is case- and whitespace-insensitive" do
      assert WorkflowRouter.select([" Life "], [@life], @code).name == "life"
      upper = %{name: "u", match_labels: [" FINANCE ", "Recurring"]}
      assert WorkflowRouter.select(["finance", "recurring"], [upper], @code).name == "u"
    end

    test "accepts an Issue struct" do
      issue = %Issue{id: "1", identifier: "T-1", labels: ["life"]}
      assert WorkflowRouter.select(issue, [@life], @code).name == "life"
    end
  end

  describe "matches?/2" do
    test "true when all required labels present" do
      assert WorkflowRouter.matches?(@finance, MapSet.new(["finance", "recurring", "extra"]))
    end

    test "false when a required label is missing" do
      refute WorkflowRouter.matches?(@finance, MapSet.new(["finance"]))
    end

    test "false for empty match_labels" do
      refute WorkflowRouter.matches?(@code, MapSet.new(["anything"]))
    end
  end
end
