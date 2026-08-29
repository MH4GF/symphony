defmodule SymphonyElixir.GitHub.Writes do
  @moduledoc """
  Host-side GitHub issue writes used by the review watcher.

  The generic tracker interface is read-only: agent-side mutations go through
  the provider-native `github_api` tool. The review watcher runs outside an
  agent turn, so it needs its own write path.
  """

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    {:error, :not_implemented}
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    {:error, :not_implemented}
  end
end
