defmodule SymphonyElixir.ReviewWatcher do
  @moduledoc """
  Returns issues parked in a review state back to an active state when their
  pull request stops being mergeable.

  Symphony hands an issue to a human once the agent reaches a review state, and
  stops polling it. A pull request that conflicts after that point would sit
  unmergeable until someone notices. This watcher closes that gap: it inspects
  the pull request behind each review-state issue and, when GitHub reports a
  conflict, comments on the issue and moves it back to a configured active
  state so the regular dispatch loop resumes the agent.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, GitHub, Issue, Orchestrator, Tracker, Workspace}

  @default_interval_ms 600_000
  @conflicting "CONFLICTING"
  @open "OPEN"

  defmodule State do
    @moduledoc false

    defstruct returned_head_oids: %{}

    @type t :: %__MODULE__{returned_head_oids: %{optional(String.t()) => String.t()}}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %State{}}
  end

  @impl true
  def handle_info(:tick, state) do
    updated_state = scan(state)
    schedule_tick()
    {:noreply, updated_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec scan_for_test(term()) :: term()
  def scan_for_test(%State{} = state), do: scan(state)

  defp schedule_tick do
    Process.send_after(self(), :tick, interval_ms())
  end

  defp interval_ms do
    case Config.settings() do
      {:ok, settings} -> settings.review_watch.interval_ms
      {:error, _reason} -> @default_interval_ms
    end
  end

  defp scan(state) do
    case Config.settings() do
      {:ok, %{review_watch: %{enabled: true} = review_watch, tracker: tracker}} ->
        scan_review_issues(state, review_watch, tracker.required_labels)

      _settings ->
        state
    end
  end

  defp scan_review_issues(state, review_watch, required_labels) do
    with {:ok, running_issue_ids} <- running_issue_ids(),
         {:ok, issues} <- Tracker.fetch_issues_by_states(review_watch.states) do
      issues
      |> Enum.filter(&Issue.routable?(&1, required_labels))
      |> Enum.reject(&MapSet.member?(running_issue_ids, &1.id))
      |> Enum.reduce(state, &check_issue(&1, &2, review_watch))
    else
      {:error, reason} ->
        Logger.warning("Review watch scan skipped reason=#{inspect(reason)}")
        state
    end
  end

  # Acting on an issue whose agent is still running would dispatch a second run
  # against the same workspace, so an unreadable orchestrator snapshot skips the
  # whole tick rather than assuming nothing is running.
  defp running_issue_ids do
    case Orchestrator.snapshot() do
      %{running: running} when is_list(running) ->
        {:ok, MapSet.new(running, & &1.issue_id)}

      other ->
        {:error, {:orchestrator_snapshot_unavailable, other}}
    end
  end

  defp check_issue(%Issue{} = issue, state, review_watch) do
    with {:ok, workspace} <- workspace_for(issue),
         {:ok, pull_request} <-
           github_module().pull_request_for_workspace(workspace, review_watch.command_timeout_ms) do
      handle_pull_request(issue, pull_request, state, review_watch)
    else
      :skip ->
        state

      {:error, reason} ->
        Logger.debug("Review watch pull request lookup skipped #{issue_log_context(issue)} reason=#{inspect(reason)}")

        state
    end
  end

  defp handle_pull_request(
         %Issue{} = issue,
         %{state: @open, mergeable: @conflicting} = pull_request,
         state,
         review_watch
       ) do
    case Map.get(state.returned_head_oids, issue.id) == pull_request.head_oid do
      true -> state
      false -> return_issue(issue, pull_request, state, review_watch)
    end
  end

  defp handle_pull_request(_issue, _pull_request, state, _review_watch), do: state

  defp return_issue(%Issue{} = issue, pull_request, state, review_watch) do
    target_state = review_watch.on_conflict_state

    with :ok <- Tracker.create_comment(issue.id, conflict_comment(pull_request, target_state)),
         :ok <- Tracker.update_issue_state(issue.id, target_state) do
      Logger.info("Review watch returned conflicting issue #{issue_log_context(issue)} pr_number=#{pull_request.number} target_state=#{target_state}")

      %{state | returned_head_oids: Map.put(state.returned_head_oids, issue.id, pull_request.head_oid)}
    else
      {:error, reason} ->
        Logger.warning("Review watch return failed #{issue_log_context(issue)} pr_number=#{pull_request.number} reason=#{inspect(reason)}")

        state
    end
  end

  defp conflict_comment(pull_request, target_state) do
    """
    Symphony detected merge conflicts on #{pull_request.url}.

    This issue moved back to `#{target_state}` so the agent resumes in its existing
    workspace. Merge the base branch into the pull request branch, resolve the
    conflicts, push, and return the issue to review.
    """
  end

  defp workspace_for(%Issue{identifier: identifier}) when is_binary(identifier) do
    case Workspace.local_path_for_issue(identifier) do
      {:ok, workspace} ->
        case File.dir?(workspace) do
          true -> {:ok, workspace}
          false -> :skip
        end

      {:error, _reason} ->
        :skip
    end
  end

  defp workspace_for(%Issue{}), do: :skip

  defp github_module do
    Application.get_env(:symphony_elixir, :github_module, GitHub)
  end

  defp issue_log_context(%Issue{id: id, identifier: identifier}) do
    "issue_id=#{inspect(id)} issue_identifier=#{inspect(identifier)}"
  end
end
