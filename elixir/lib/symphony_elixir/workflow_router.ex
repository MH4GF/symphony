defmodule SymphonyElixir.WorkflowRouter do
  @moduledoc """
  Selects a workflow definition for an issue by label.

  Each workflow declares `:match_labels`. An issue routes to the first workflow
  whose match labels are all present on the issue (case- and whitespace-
  insensitive). If no workflow matches, the supplied default is returned.

  The normalized issue carries labels but not team/project, so routing is
  label-based. A workflow with empty `:match_labels` never auto-matches; it is
  only usable as the explicit default (e.g. the code workflow).
  """

  alias SymphonyElixir.Issue

  @doc """
  Return the first workflow whose `:match_labels` are all present on the issue,
  or `default` when none match. Workflows are tried in list order.
  """
  @spec select(Issue.t() | [String.t()], [map()], map()) :: map()
  def select(issue_or_labels, workflows, default) when is_list(workflows) do
    labels = normalize_labels(issue_labels(issue_or_labels))
    Enum.find(workflows, default, &matches?(&1, labels))
  end

  @doc """
  Whether a workflow matches a normalized set of issue labels. A workflow with
  no `:match_labels` never matches.
  """
  @spec matches?(map(), MapSet.t()) :: boolean()
  def matches?(workflow, %MapSet{} = issue_labels) do
    required = workflow |> Map.get(:match_labels, []) |> normalize_labels()
    not Enum.empty?(required) and MapSet.subset?(required, issue_labels)
  end

  defp issue_labels(%Issue{} = issue), do: Issue.label_names(issue)
  defp issue_labels(labels) when is_list(labels), do: labels

  defp normalize_labels(labels) when is_list(labels) do
    MapSet.new(labels, &normalize_label/1)
  end

  defp normalize_label(label) when is_binary(label) do
    label |> String.trim() |> String.downcase()
  end
end
