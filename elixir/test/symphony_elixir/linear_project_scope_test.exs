defmodule SymphonyElixir.Linear.ProjectScopeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Adapter, as: LinearAdapter

  test "the adapter accepts a tracker without a project slug" do
    assert :ok = LinearAdapter.validate_config(tracker_settings(nil))
    assert :ok = LinearAdapter.validate_config(tracker_settings("project"))

    assert {:error, :missing_linear_api_token} =
             LinearAdapter.validate_config(%{tracker_settings("project") | api_key: nil})
  end

  test "an unscoped ID refresh drops the project filter from the query" do
    graphql_fun = fn query, variables ->
      send(self(), {:graphql, query, variables})
      {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}
    end

    assert {:ok, []} = Client.fetch_issues_by_ids_for_test(["issue-1"], graphql_fun, nil)

    assert_received {:graphql, query, variables}
    refute query =~ "projectSlug"
    refute Map.has_key?(variables, :projectSlug)
    assert variables.ids == ["issue-1"]
  end

  test "a scoped ID refresh keeps the project filter" do
    graphql_fun = fn query, variables ->
      send(self(), {:graphql, query, variables})
      {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}
    end

    assert {:ok, []} = Client.fetch_issues_by_ids_for_test(["issue-1"], graphql_fun, "acme")

    assert_received {:graphql, query, variables}
    assert query =~ "projectSlug"
    assert variables.projectSlug == "acme"
  end

  defp tracker_settings(project_slug) do
    %{
      kind: "linear",
      endpoint: "https://api.linear.app/graphql",
      api_key: "token",
      project_slug: project_slug,
      assignee: nil
    }
  end
end
