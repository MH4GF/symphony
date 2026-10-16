defmodule Mix.Tasks.Prompt.Render do
  use Mix.Task

  @shortdoc "Render the first-turn agent prompt for a Linear issue"

  @moduledoc """
  Renders the prompt that Symphony would send on the first agent turn for one
  Linear issue, so it can be pasted into an interactive coding-agent session.

  The prompt is written to stdout; diagnostics go to stderr. The orchestrator is
  not started, so no issue is dispatched.

  Usage:

      mix prompt.render --workflow path/to/WORKFLOW.md https://linear.app/acme/issue/ABC-123/some-title
      mix prompt.render --workflow path/to/WORKFLOW.md ABC-123 --attempt 2
  """

  alias SymphonyElixir.{Linear.Client, PromptBuilder, Workflow}

  @identifier_pattern ~r/\A[A-Za-z0-9]+-\d+\z/
  @url_identifier_pattern ~r{/issue/([A-Za-z0-9]+-\d+)}

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [workflow: :string, attempt: :integer, help: :boolean],
        aliases: [w: :workflow, h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      is_nil(opts[:workflow]) ->
        Mix.raise("Missing required --workflow option")

      true ->
        issue_ref = single_issue_ref!(argv)
        render(opts[:workflow], issue_ref, opts[:attempt])
    end
  end

  defp render(workflow_path, issue_ref, attempt) do
    identifier = parse_identifier!(issue_ref)

    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:req)
    Workflow.set_workflow_file_path(Path.expand(workflow_path))

    case client_module().fetch_issue_by_identifier(identifier) do
      {:ok, issue} ->
        IO.write(PromptBuilder.build_prompt(issue, attempt: attempt))

      {:error, reason} ->
        Mix.raise("Failed to fetch Linear issue #{identifier}: #{inspect(reason)}")
    end
  end

  defp single_issue_ref!([issue_ref]), do: issue_ref
  defp single_issue_ref!(_argv), do: Mix.raise("Expected exactly one Linear issue URL or identifier")

  defp parse_identifier!(issue_ref) do
    cond do
      Regex.match?(@identifier_pattern, issue_ref) ->
        String.upcase(issue_ref)

      match = Regex.run(@url_identifier_pattern, issue_ref, capture: :all_but_first) ->
        match |> hd() |> String.upcase()

      true ->
        Mix.raise("Could not find a Linear issue identifier in #{inspect(issue_ref)}")
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end
end
