defmodule SymphonyElixir.Linear.WritesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Writes

  test "create_comment sends commentCreate for the issue" do
    test_pid = self()

    assert :ok =
             Writes.create_comment("lin-1", "conflict",
               tracker_settings: tracker_settings(),
               request_fun: fn payload, headers ->
                 send(test_pid, {:called, payload, headers})
                 ok(%{"data" => %{"commentCreate" => %{"success" => true}}})
               end
             )

    assert_received {:called, %{"query" => query, "variables" => %{issueId: "lin-1", body: "conflict"}}, headers}
    assert query =~ "commentCreate"
    assert {"Authorization", "token"} in headers
  end

  test "update_issue_state resolves the team state by name before updating" do
    test_pid = self()

    assert :ok =
             Writes.update_issue_state("lin-1", "In Progress",
               tracker_settings: tracker_settings(),
               request_fun: fn %{"query" => query, "variables" => variables}, _headers ->
                 send(test_pid, {:called, variables})

                 case query =~ "issueUpdate" do
                   true -> ok(%{"data" => %{"issueUpdate" => %{"success" => true}}})
                   false -> ok(states_response([%{"id" => "state-2"}]))
                 end
               end
             )

    assert_received {:called, %{issueId: "lin-1", stateName: "In Progress"}}
    assert_received {:called, %{issueId: "lin-1", stateId: "state-2"}}
  end

  test "an unknown state name is reported without updating the issue" do
    test_pid = self()

    assert {:error, {:linear_state_not_found, "Nope"}} =
             Writes.update_issue_state("lin-1", "Nope",
               tracker_settings: tracker_settings(),
               request_fun: fn %{"variables" => variables}, _headers ->
                 send(test_pid, {:called, variables})
                 ok(states_response([]))
               end
             )

    assert_received {:called, %{stateName: "Nope"}}
    refute_received {:called, %{stateId: _state_id}}
  end

  test "GraphQL errors and unsuccessful mutations surface as errors" do
    errors = [%{"message" => "forbidden"}]

    assert {:error, {:linear_graphql_errors, ^errors}} =
             Writes.create_comment("lin-1", "conflict",
               tracker_settings: tracker_settings(),
               request_fun: fn _payload, _headers -> ok(%{"errors" => errors}) end
             )

    assert {:error, {:linear_graphql_errors, ^errors}} =
             Writes.update_issue_state("lin-1", "In Progress",
               tracker_settings: tracker_settings(),
               request_fun: fn _payload, _headers -> ok(%{"errors" => errors}) end
             )

    assert {:error, :comment_create_failed} =
             Writes.create_comment("lin-1", "conflict",
               tracker_settings: tracker_settings(),
               request_fun: fn _payload, _headers -> ok(%{"data" => %{"commentCreate" => %{"success" => false}}}) end
             )

    assert {:error, :issue_update_failed} =
             Writes.update_issue_state("lin-1", "In Progress",
               tracker_settings: tracker_settings(),
               request_fun: fn %{"query" => query}, _headers ->
                 case query =~ "issueUpdate" do
                   true -> ok(%{"unexpected" => true})
                   false -> ok(states_response([%{"id" => "state-2"}]))
                 end
               end
             )
  end

  test "a non-200 response is reported as a Linear API error" do
    log =
      capture_log(fn ->
        assert {:error, {:linear_api_status, 500}} =
                 Writes.create_comment("lin-1", "conflict",
                   tracker_settings: tracker_settings(),
                   request_fun: fn _payload, _headers -> {:ok, %{status: 500, body: "boom"}} end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=500"
  end

  defp ok(body), do: {:ok, %{status: 200, body: body}}

  defp states_response(nodes) do
    %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => nodes}}}}}
  end

  defp tracker_settings do
    %{kind: "linear", endpoint: "https://api.linear.app/graphql", api_key: "token"}
  end
end
