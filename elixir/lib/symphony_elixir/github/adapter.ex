defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub Issues-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHub.{AgentTool, Client}
  alias SymphonyElixir.Tracker.Issue

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    with :ok <- validate_states(tracker_settings.active_states, :missing_github_active_states),
         :ok <- validate_states(tracker_settings.terminal_states, :missing_github_terminal_states) do
      Client.validate_settings(tracker_settings)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: client_module().fetch_issues_by_ids(issue_ids)

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings), do: Client.secret_environment_names(tracker_settings)

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end

  # State is carried by status:* labels rather than GitHub's own open/closed, so
  # any workflow state name is valid as long as it is a usable string.
  defp validate_states(states, _missing_error) when is_list(states) do
    if Enum.all?(states, &present_string?/1) do
      :ok
    else
      {:error, :invalid_github_states}
    end
  end

  defp validate_states(_states, missing_error), do: {:error, missing_error}

  defp present_string?(state) when is_binary(state), do: String.trim(state) != ""
  defp present_string?(_state), do: false
end
