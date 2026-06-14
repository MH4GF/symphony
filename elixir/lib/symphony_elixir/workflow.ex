defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads workflow configuration and prompt from WORKFLOW.md.
  """

  alias SymphonyElixir.WorkflowStore

  @workflow_file_name "WORKFLOW.md"

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join(File.cwd!(), @workflow_file_name)
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t(),
          prompts: [prompt_variant()]
        }

  @typedoc """
  A prompt variant for label-based routing. Selected by `WorkflowRouter` against
  the issue labels. `:template` is the rendered prompt body; `:handoff_state` is
  the workflow's desired terminal Linear state when work succeeds (informational
  for the agent prompt and for future orchestrator wiring).
  """
  @type prompt_variant :: %{
          name: String.t(),
          match_labels: [String.t()],
          template: String.t(),
          handoff_state: String.t() | nil
        }

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current()

      _ ->
        load()
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content)

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  defp parse(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()
        prompts = extract_prompts(front_matter)

        {:ok,
         %{
           config: front_matter,
           prompt: prompt,
           prompt_template: prompt,
           prompts: prompts
         }}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  # `prompts:` is an optional frontmatter list (SPEC extension; unknown keys are
  # ignored by the config schema). Each entry has `name`, `match_labels`,
  # `template`, and an optional `handoff_state`.
  defp extract_prompts(%{"prompts" => list}) when is_list(list) do
    Enum.flat_map(list, &normalize_prompt_entry/1)
  end

  defp extract_prompts(_), do: []

  defp normalize_prompt_entry(%{"template" => template} = entry) when is_binary(template) do
    [
      %{
        name: to_string(Map.get(entry, "name", "")),
        match_labels: list_of_strings(Map.get(entry, "match_labels", [])),
        template: template,
        handoff_state: nilable_string(Map.get(entry, "handoff_state"))
      }
    ]
  end

  defp normalize_prompt_entry(_), do: []

  defp list_of_strings(list) when is_list(list) do
    Enum.filter(list, &is_binary/1)
  end

  defp list_of_strings(_), do: []

  defp nilable_string(s) when is_binary(s), do: s
  defp nilable_string(_), do: nil

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end
end
