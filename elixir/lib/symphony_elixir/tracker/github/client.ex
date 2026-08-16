defmodule SymphonyElixir.Tracker.GitHub.Client do
  @moduledoc """
  GitHub Issues REST client backing the GitHub tracker adapter.

  Candidate issues are read by listing open issues and filtering on `status:*`
  labels rather than by search. Search indexing lags behind writes, which the
  dispatch loop cannot tolerate, and the repositories in scope hold few open
  issues so listing them is cheap.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.GitHub.Mapper

  @page_size 100
  @max_pages 20
  @closed_lookback_seconds 30 * 24 * 60 * 60
  @token_ttl_ms 45 * 60 * 1_000
  @default_token_helper "~/.hermes/bin/gh-app-token"
  @connect_timeout_ms 30_000
  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    fetch_issues_by_states(Config.settings!().tracker.active_states)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    states = state_names |> Enum.map(&to_string/1) |> Enum.uniq()
    {terminal_states, open_states} = Enum.split_with(states, &Mapper.terminal_state?/1)

    with {:ok, open_issues} <- fetch_open_issues(open_states),
         {:ok, closed_issues} <- fetch_closed_issues(terminal_states) do
      {:ok, open_issues ++ closed_issues}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    issue_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
      case fetch_issue(issue_id) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, request} <- request_options() do
      request
      |> post("/repos/#{repo(request)}/issues/#{issue_id}/comments", %{body: body})
      |> case do
        {:ok, _payload} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Moves an issue to `state_name`.

  Terminal states close the issue and strip its `status:*` label. Every other
  state sends the full label list with exactly one `status:*` entry, which makes
  the transition atomic because GitHub replaces the label set wholesale.
  """
  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, request} <- request_options(),
         {:ok, payload} when is_map(payload) <-
           get(request, "/repos/#{repo(request)}/issues/#{issue_id}") do
      current_labels = current_label_names(payload)

      request
      |> patch(
        "/repos/#{repo(request)}/issues/#{issue_id}",
        state_update_body(state_name, current_labels)
      )
      |> case do
        {:ok, _updated} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, _payload} -> {:error, :github_unexpected_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp state_update_body(state_name, current_labels) do
    case Mapper.terminal_state?(state_name) do
      true ->
        %{
          state: "closed",
          state_reason: close_reason(state_name),
          labels: Mapper.apply_status_label(current_labels, nil)
        }

      false ->
        %{state: "open", labels: Mapper.apply_status_label(current_labels, state_name)}
    end
  end

  defp close_reason(state_name) do
    case state_name == Mapper.not_planned_state() do
      true -> "not_planned"
      false -> "completed"
    end
  end

  defp current_label_names(payload) do
    payload
    |> Map.get("labels", [])
    |> List.wrap()
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> name
      name when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_open_issues([]), do: {:ok, []}

  defp fetch_open_issues(states) do
    with {:ok, issues} <- list_issues(%{state: "open"}) do
      {:ok, filter_by_states(issues, states)}
    end
  end

  defp fetch_closed_issues([]), do: {:ok, []}

  defp fetch_closed_issues(states) do
    since =
      DateTime.utc_now()
      |> DateTime.add(-@closed_lookback_seconds, :second)
      |> DateTime.to_iso8601()

    with {:ok, issues} <- list_issues(%{state: "closed", since: since, sort: "updated"}) do
      {:ok, filter_by_states(issues, states)}
    end
  end

  defp filter_by_states(issues, states) do
    allowed = MapSet.new(states)
    Enum.filter(issues, &MapSet.member?(allowed, &1.state))
  end

  defp fetch_issue(issue_id) do
    with {:ok, request} <- request_options() do
      case get(request, "/repos/#{repo(request)}/issues/#{issue_id}") do
        {:ok, payload} when is_map(payload) -> {:ok, Mapper.normalize(payload, known_states())}
        {:ok, _payload} -> {:error, :github_unexpected_payload}
        {:error, {:github_http_error, 404, _body}} -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp list_issues(params) do
    with {:ok, request} <- request_options() do
      known = known_states()

      Enum.reduce_while(1..@max_pages, {:ok, []}, fn page, {:ok, acc} ->
        list_issues_page(request, params, known, page, acc)
      end)
    end
  end

  defp list_issues_page(request, params, known, page, acc) do
    query = Map.merge(params, %{per_page: @page_size, page: page})

    case get(request, "/repos/#{repo(request)}/issues", query) do
      {:ok, payload} when is_list(payload) -> accumulate_page(payload, known, acc)
      {:ok, _payload} -> {:halt, {:error, :github_unexpected_payload}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp accumulate_page(payload, known, acc) do
    issues = payload |> Enum.map(&Mapper.normalize(&1, known)) |> Enum.reject(&is_nil/1)
    accumulated = {:ok, acc ++ issues}

    case length(payload) < @page_size do
      true -> {:halt, accumulated}
      false -> {:cont, accumulated}
    end
  end

  @doc """
  State names the adapter can resolve a `status:*` label back to.

  Ordering decides which label wins when an issue carries more than one, so the
  configured active states come first.
  """
  @spec known_states() :: [String.t()]
  def known_states do
    settings = Config.settings!()
    review_watch = Map.get(settings, :review_watch)

    (settings.tracker.active_states ++
       settings.tracker.terminal_states ++
       review_watch_states(review_watch) ++
       [Mapper.default_open_state()])
    |> Enum.reject(&(!is_binary(&1) or &1 == ""))
    |> Enum.uniq()
  end

  defp review_watch_states(nil), do: []

  defp review_watch_states(review_watch) do
    List.wrap(Map.get(review_watch, :states)) ++ List.wrap(Map.get(review_watch, :on_conflict_state))
  end

  defp repo(%{repo: repo}), do: repo

  defp request_options do
    settings = Config.settings!()

    with {:ok, repo} <- validate_repo(settings.tracker.repo),
         {:ok, token} <- resolve_token(settings.tracker.token) do
      {:ok, %{repo: repo, token: token, base_url: settings.tracker.endpoint}}
    end
  end

  defp validate_repo(repo) when is_binary(repo) do
    case String.split(repo, "/", trim: true) do
      [_owner, _name] -> {:ok, repo}
      _ -> {:error, {:invalid_github_repo, repo}}
    end
  end

  defp validate_repo(_repo), do: {:error, :missing_github_repo}

  defp resolve_token(token) when is_binary(token) and token != "", do: {:ok, token}
  defp resolve_token(_token), do: cached_helper_token()

  defp cached_helper_token do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, :token}, nil) do
      {token, expires_at} when expires_at > now -> {:ok, token}
      _expired -> mint_helper_token(now)
    end
  end

  defp mint_helper_token(now) do
    helper = token_helper_path()

    case File.regular?(helper) do
      false ->
        {:error, :missing_github_token}

      true ->
        case System.cmd(helper, [], stderr_to_stdout: true) do
          {output, 0} ->
            token = String.trim(output)
            :persistent_term.put({__MODULE__, :token}, {token, now + @token_ttl_ms})
            {:ok, token}

          {output, status} ->
            {:error, {:github_token_helper_failed, status, truncate(output)}}
        end
    end
  end

  defp token_helper_path do
    case System.get_env("SYMPHONY_GH_TOKEN_HELPER") do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> Path.expand(@default_token_helper)
    end
  end

  defp get(request, path, params \\ %{}) do
    Req.get(url(request, path),
      headers: headers(request),
      params: Map.to_list(params),
      connect_options: [timeout: @connect_timeout_ms]
    )
    |> handle_response()
  end

  defp post(request, path, body) do
    Req.post(url(request, path),
      headers: headers(request),
      json: body,
      connect_options: [timeout: @connect_timeout_ms]
    )
    |> handle_response()
  end

  defp patch(request, path, body) do
    Req.patch(url(request, path),
      headers: headers(request),
      json: body,
      connect_options: [timeout: @connect_timeout_ms]
    )
    |> handle_response()
  end

  defp url(%{base_url: base_url}, path), do: String.trim_trailing(base_url, "/") <> path

  defp headers(%{token: token}) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"},
      {"User-Agent", "symphony-elixir"}
    ]
  end

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    Logger.warning("GitHub API returned #{status} body=#{summarize_error_body(body)}")
    {:error, {:github_http_error, status, summarize_error_body(body)}}
  end

  defp handle_response({:error, reason}), do: {:error, {:github_request_failed, reason}}

  defp summarize_error_body(body) when is_binary(body) do
    body |> String.replace(~r/\s+/, " ") |> String.trim() |> truncate()
  end

  defp summarize_error_body(body), do: body |> inspect(limit: 20) |> truncate()

  defp truncate(value) when is_binary(value) do
    case byte_size(value) > @max_error_body_log_bytes do
      true -> binary_part(value, 0, @max_error_body_log_bytes) <> "...<truncated>"
      false -> value
    end
  end
end
