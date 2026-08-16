defmodule SymphonyElixir.Tracker.GitHub.Mapper do
  @moduledoc """
  Pure mapping between GitHub issue payloads and the orchestrator issue struct.

  State lives on the issue itself. `status:*` labels carry the non-terminal
  states, and closed/`state_reason` carries the terminal ones. Exactly one
  `status:*` label is expected; when more than one is present the first match in
  `known_states` order wins so the resolution stays deterministic.
  """

  alias SymphonyElixir.Issue

  @status_prefix "status:"
  @priority_prefix "priority:"
  @completed_state "Done"
  @not_planned_state "Canceled"
  @default_open_state "Backlog"
  @max_branch_slug_length 60

  @spec completed_state() :: String.t()
  def completed_state, do: @completed_state

  @spec not_planned_state() :: String.t()
  def not_planned_state, do: @not_planned_state

  @spec default_open_state() :: String.t()
  def default_open_state, do: @default_open_state

  @spec terminal_state?(term()) :: boolean()
  def terminal_state?(state), do: state in [@completed_state, @not_planned_state]

  @spec status_label(String.t()) :: String.t()
  def status_label(state_name) when is_binary(state_name), do: @status_prefix <> slug(state_name)

  @doc """
  Returns the full label list to send when moving an issue to `state_name`.

  GitHub replaces the whole label set on update, so dropping every existing
  `status:*` label here makes the transition atomic.
  """
  @spec apply_status_label([String.t()], String.t() | nil) :: [String.t()]
  def apply_status_label(current_labels, nil) when is_list(current_labels) do
    Enum.reject(current_labels, &status_label?/1)
  end

  def apply_status_label(current_labels, state_name)
      when is_list(current_labels) and is_binary(state_name) do
    Enum.reject(current_labels, &status_label?/1) ++ [status_label(state_name)]
  end

  @spec status_label?(String.t()) :: boolean()
  def status_label?(label) when is_binary(label) do
    label |> String.downcase() |> String.starts_with?(@status_prefix)
  end

  def status_label?(_label), do: false

  @doc """
  Converts a GitHub issue payload into the orchestrator issue struct.

  Returns `nil` for pull requests, which the issues endpoint also lists.
  """
  @spec normalize(map(), [String.t()]) :: Issue.t() | nil
  def normalize(payload, known_states) when is_map(payload) and is_list(known_states) do
    case pull_request?(payload) do
      true ->
        nil

      false ->
        build(payload, known_states)
    end
  end

  def normalize(_payload, _known_states), do: nil

  @spec branch_name(integer(), String.t() | nil) :: String.t()
  def branch_name(number, title) when is_integer(number) do
    case slug(title || "") do
      "" -> "symphony/#{number}"
      slug -> "symphony/#{number}-#{String.slice(slug, 0, @max_branch_slug_length)}"
    end
  end

  defp build(payload, known_states) do
    number = payload["number"]
    labels = extract_labels(payload)

    case is_integer(number) do
      false ->
        nil

      true ->
        %Issue{
          id: Integer.to_string(number),
          identifier: "##{number}",
          title: payload["title"],
          description: payload["body"],
          priority: priority_from_labels(labels),
          state: resolve_state(payload, labels, known_states),
          branch_name: branch_name(number, payload["title"]),
          url: payload["html_url"],
          assignee_id: get_in(payload, ["assignee", "login"]),
          blocked_by: [],
          labels: labels,
          assigned_to_worker: true,
          created_at: parse_datetime(payload["created_at"]),
          updated_at: parse_datetime(payload["updated_at"])
        }
    end
  end

  defp pull_request?(payload), do: Map.has_key?(payload, "pull_request")

  defp resolve_state(payload, labels, known_states) do
    case payload["state"] do
      "closed" -> closed_state(payload["state_reason"])
      _open -> state_from_labels(labels, known_states) || @default_open_state
    end
  end

  defp closed_state("not_planned"), do: @not_planned_state
  defp closed_state(_state_reason), do: @completed_state

  @doc """
  Resolves the state name carried by `labels`, preferring `known_states` order.

  A `status:*` label outside `known_states` falls back to the label slug read
  back as a state name, so an unconfigured state never reads as `Backlog`.
  """
  @spec state_from_labels([String.t()], [String.t()]) :: String.t() | nil
  def state_from_labels(labels, known_states) when is_list(labels) and is_list(known_states) do
    present = MapSet.new(labels, &String.downcase/1)

    Enum.find_value(known_states, fn state ->
      case MapSet.member?(present, status_label(state)) do
        true -> state
        false -> nil
      end
    end) || unknown_status_state(labels)
  end

  defp unknown_status_state(labels) do
    labels
    |> Enum.filter(&status_label?/1)
    |> List.first()
    |> case do
      nil -> nil
      label -> label |> String.downcase() |> String.replace_prefix(@status_prefix, "") |> deslug()
    end
  end

  defp deslug(slug) do
    slug
    |> String.split("-", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @spec priority_from_labels([String.t()]) :: integer() | nil
  def priority_from_labels(labels) when is_list(labels) do
    Enum.find_value(labels, fn label ->
      with true <- is_binary(label),
           downcased <- String.downcase(label),
           true <- String.starts_with?(downcased, @priority_prefix),
           {value, ""} <- Integer.parse(String.replace_prefix(downcased, @priority_prefix, "")),
           true <- value in 1..4 do
        value
      else
        _ -> nil
      end
    end)
  end

  defp extract_labels(payload) do
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

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp slug(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end
