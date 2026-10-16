defmodule SymphonyElixir.Linear.Writes do
  @moduledoc """
  Host-side Linear issue writes used by the review watcher.

  The generic tracker interface is read-only: agent-side mutations go through
  the provider-native `linear_graphql` tool. The review watcher runs outside an
  agent turn, so it needs its own write path.
  """

  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_id, body, opts \\ []) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- graphql(@create_comment_mutation, %{issueId: issue_id, body: body}, opts) do
      mutation_result(response, "commentCreate", :comment_create_failed)
    end
  end

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name, opts \\ [])
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name, opts),
         {:ok, response} <- graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}, opts) do
      mutation_result(response, "issueUpdate", :issue_update_failed)
    end
  end

  defp resolve_state_id(issue_id, state_name, opts) do
    with {:ok, response} <- graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}, opts) do
      state_id_result(response, state_name)
    end
  end

  defp state_id_result(%{"errors" => errors}, _state_name), do: {:error, {:linear_graphql_errors, errors}}

  defp state_id_result(response, state_name) do
    case get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      state_id when is_binary(state_id) -> {:ok, state_id}
      _missing -> {:error, {:linear_state_not_found, state_name}}
    end
  end

  defp mutation_result(%{"errors" => errors}, _field, _failure), do: {:error, {:linear_graphql_errors, errors}}
  defp mutation_result(%{"data" => %{} = data}, field, failure), do: success_result(get_in(data, [field, "success"]), failure)
  defp mutation_result(_response, _field, failure), do: {:error, failure}

  defp success_result(true, _failure), do: :ok
  defp success_result(_success, failure), do: {:error, failure}

  defp graphql(query, variables, opts) do
    client_module().graphql(query, variables, Keyword.take(opts, [:tracker_settings, :request_fun]))
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end
end
