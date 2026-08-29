defmodule SymphonyElixir.GitHub.WritesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.Writes

  test "create_comment posts the body to the issue" do
    test_pid = self()

    assert :ok =
             Writes.create_comment("42", "conflict",
               tracker_settings: tracker_settings(),
               request_fun: fn method, path, params, body, _settings ->
                 send(test_pid, {:called, method, path, params, body})
                 {:ok, %{status: 201, body: %{"id" => 9}}}
               end
             )

    assert_received {:called, "POST", "/repos/octo/repo/issues/42/comments", %{}, %{body: "conflict"}}
  end

  test "moving an issue to a non-terminal state swaps the status label and keeps it open" do
    test_pid = self()

    assert :ok =
             Writes.update_issue_state("42", "In Progress",
               tracker_settings: tracker_settings(),
               request_fun: fn
                 "GET", "/repos/octo/repo/issues/42", _params, _body, _settings ->
                   {:ok, %{status: 200, body: %{"labels" => [%{"name" => "status:todo"}, %{"name" => "bug"}]}}}

                 "PATCH", path, _params, body, _settings ->
                   send(test_pid, {:patched, path, body})
                   {:ok, %{status: 200, body: %{}}}
               end
             )

    assert_received {:patched, "/repos/octo/repo/issues/42", %{state: "open", labels: ["bug", "status:in-progress"]}}
  end

  test "moving an issue to a terminal state closes it and strips the status label" do
    test_pid = self()

    assert :ok =
             Writes.update_issue_state("42", "Done",
               tracker_settings: tracker_settings(),
               request_fun: fn
                 "GET", _path, _params, _body, _settings ->
                   {:ok, %{status: 200, body: %{"labels" => ["status:in-progress", "bug"]}}}

                 "PATCH", _path, _params, body, _settings ->
                   send(test_pid, {:patched, body})
                   {:ok, %{status: 200, body: %{}}}
               end
             )

    assert_received {:patched, %{state: "closed", state_reason: "completed", labels: ["bug"]}}
  end

  test "the not-planned state closes the issue with state_reason not_planned" do
    test_pid = self()

    assert :ok =
             Writes.update_issue_state("42", "Canceled",
               tracker_settings: tracker_settings(),
               request_fun: fn
                 "GET", _path, _params, _body, _settings ->
                   {:ok, %{status: 200, body: %{}}}

                 "PATCH", _path, _params, body, _settings ->
                   send(test_pid, {:patched, body})
                   {:ok, %{status: 200, body: %{}}}
               end
             )

    assert_received {:patched, %{state: "closed", state_reason: "not_planned", labels: []}}
  end

  test "a failed read surfaces the error and issues no write" do
    assert {:error, {:github_api_status, 403}} =
             Writes.update_issue_state("42", "In Progress",
               tracker_settings: tracker_settings(),
               request_fun: fn
                 "GET", _path, _params, _body, _settings -> {:ok, %{status: 403, body: %{}}}
                 "PATCH", _path, _params, _body, _settings -> flunk("a failed read must not write")
               end
             )
  end

  test "a malformed issue payload is rejected" do
    assert {:error, :github_unknown_payload} =
             Writes.update_issue_state("42", "In Progress",
               tracker_settings: tracker_settings(),
               request_fun: fn "GET", _path, _params, _body, _settings -> {:ok, %{status: 200, body: "nope"}} end
             )
  end

  test "missing repository settings fail before any request" do
    assert {:error, :missing_github_repo} =
             Writes.create_comment("42", "body",
               tracker_settings: %{kind: "github", provider: %{"token" => "test-token"}},
               request_fun: fn _method, _path, _params, _body, _settings -> flunk("must not request") end
             )
  end

  defp tracker_settings do
    %{
      kind: "github",
      provider: %{"repo" => "octo/repo", "token" => "test-token"},
      active_states: ["Todo", "In Progress"],
      terminal_states: ["Done", "Canceled"]
    }
  end
end
