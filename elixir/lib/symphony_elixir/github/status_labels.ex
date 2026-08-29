defmodule SymphonyElixir.GitHub.StatusLabels do
  @moduledoc """
  Maps Symphony workflow states onto GitHub issue state.

  GitHub issues carry only `open` and `closed`, which cannot express a workflow
  that parks work in states such as `Human Review` or `Merging`. State therefore
  lives on the issue itself: `status:*` labels carry the non-terminal states and
  closed/`state_reason` carries the terminal ones. Exactly one `status:*` label
  is expected; when more than one is present the first match in `known_states`
  order wins so the resolution stays deterministic.
  """

  @status_prefix "status:"
  @priority_prefix "priority:"
  @completed_state "Done"
  @not_planned_state "Canceled"
  @default_open_state "Backlog"

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

  @spec status_label?(term()) :: boolean()
  def status_label?(label) when is_binary(label) do
    label |> String.downcase() |> String.starts_with?(@status_prefix)
  end

  def status_label?(_label), do: false

  @doc """
  Returns the full label list to send when moving an issue to `state_name`.

  GitHub replaces the whole label set on update, so dropping every existing
  `status:*` label here makes the transition atomic.
  """
  @spec apply_status_label([String.t()], String.t() | nil) :: [String.t()]
  def apply_status_label(current_labels, nil) when is_list(current_labels) do
    Enum.reject(current_labels, &status_label?/1)
  end

  def apply_status_label(current_labels, state_name) when is_list(current_labels) and is_binary(state_name) do
    Enum.reject(current_labels, &status_label?/1) ++ [status_label(state_name)]
  end

  @doc """
  Resolves the workflow state an issue payload carries.

  A closed issue takes its state from `state_reason`; an open one from its
  `status:*` label, falling back to the default open state.
  """
  @spec resolve_state(map(), [String.t()], [String.t()]) :: String.t()
  def resolve_state(payload, labels, known_states) when is_map(payload) and is_list(labels) and is_list(known_states) do
    case payload["state"] do
      "closed" -> closed_state(payload["state_reason"])
      _open -> state_from_labels(labels, known_states) || @default_open_state
    end
  end

  @doc """
  Resolves the state name carried by `labels`, preferring `known_states` order.

  A `status:*` label outside `known_states` falls back to the label slug read
  back as a state name, so an unconfigured state never reads as the default.
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

  @doc """
  State names a `status:*` label can resolve back to, in precedence order.

  Callers pass the whole settings map so this module stays free of config
  lookups and the client can thread one value through its request pipeline.
  """
  @spec known_states(map()) :: [String.t()]
  def known_states(settings) when is_map(settings) do
    tracker = Map.get(settings, :tracker) || %{}

    (List.wrap(Map.get(tracker, :active_states)) ++
       List.wrap(Map.get(tracker, :terminal_states)) ++
       review_watch_states(Map.get(settings, :review_watch)) ++
       [@default_open_state])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp review_watch_states(nil), do: []

  defp review_watch_states(review_watch) do
    List.wrap(Map.get(review_watch, :states)) ++ List.wrap(Map.get(review_watch, :on_conflict_state))
  end

  defp closed_state("not_planned"), do: @not_planned_state
  defp closed_state(_state_reason), do: @completed_state

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

  defp slug(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end
