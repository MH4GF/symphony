defmodule SymphonyElixir.GitHub.Writes do
  @moduledoc """
  Host-side GitHub issue writes used by the review watcher.

  The generic tracker interface is read-only: agent-side mutations go through
  the provider-native `github_api` tool. The review watcher runs outside an
  agent turn, so it needs its own write path.

  A state transition sends the full label list carrying exactly one `status:*`
  entry. GitHub replaces the label set wholesale, which makes the transition a
  single atomic request rather than an add followed by a remove.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.{Client, StatusLabels}

  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_id, body, opts \\ []) when is_binary(issue_id) and is_binary(body) do
    tracker_settings = tracker_settings(opts)

    with {:ok, repo} <- Client.repo(tracker_settings),
         {:ok, _payload} <-
           request("POST", issue_path(repo, issue_id) <> "/comments", %{body: body}, tracker_settings, opts) do
      :ok
    end
  end

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name, opts \\ [])
      when is_binary(issue_id) and is_binary(state_name) do
    tracker_settings = tracker_settings(opts)

    with {:ok, repo} <- Client.repo(tracker_settings),
         path <- issue_path(repo, issue_id),
         {:ok, payload} when is_map(payload) <- request("GET", path, nil, tracker_settings, opts),
         body <- state_update_body(state_name, current_label_names(payload)),
         {:ok, _updated} <- request("PATCH", path, body, tracker_settings, opts) do
      :ok
    else
      {:ok, _payload} -> {:error, :github_unknown_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp state_update_body(state_name, current_labels) do
    case StatusLabels.terminal_state?(state_name) do
      true ->
        %{
          state: "closed",
          state_reason: close_reason(state_name),
          labels: StatusLabels.apply_status_label(current_labels, nil)
        }

      false ->
        %{state: "open", labels: StatusLabels.apply_status_label(current_labels, state_name)}
    end
  end

  defp close_reason(state_name) do
    case state_name == StatusLabels.not_planned_state() do
      true -> "not_planned"
      false -> "completed"
    end
  end

  defp current_label_names(payload) do
    payload
    |> Map.get("labels", [])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _label -> []
    end)
  end

  defp request(method, path, body, tracker_settings, opts) do
    request_opts =
      opts
      |> Keyword.take([:request_fun])
      |> Keyword.put(:tracker_settings, tracker_settings)

    case Client.request(method, path, %{}, body, request_opts) do
      {:ok, %{status: status, body: payload}} when status in 200..299 -> {:ok, payload}
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_path(repo, issue_id), do: "/repos/#{repo}/issues/#{issue_id}"

  defp tracker_settings(opts) do
    Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
  end
end
