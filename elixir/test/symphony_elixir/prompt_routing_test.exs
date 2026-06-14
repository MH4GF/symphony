defmodule SymphonyElixir.PromptRoutingTest do
  @moduledoc """
  Integration tests for the `prompts:` workflow extension. Verifies that
  `Workflow.load/1` extracts prompt variants from frontmatter and that
  `PromptBuilder.build_prompt/2` selects a variant by issue labels.
  """

  use SymphonyElixir.TestSupport

  test "load/1 returns empty prompts when frontmatter has none" do
    path =
      Path.join(System.tmp_dir!(), "symphony-prompt-routing-#{System.unique_integer([:positive])}.md")

    File.write!(path, """
    ---
    tracker:
      kind: linear
      project_slug: any
    ---
    body
    """)

    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, workflow} = Workflow.load(path)
    assert workflow.prompts == []
  end

  test "load/1 extracts prompt variants from `prompts:` frontmatter" do
    path =
      Path.join(System.tmp_dir!(), "symphony-prompt-routing-#{System.unique_integer([:positive])}.md")

    File.write!(path, """
    ---
    tracker:
      kind: linear
      project_slug: any
    prompts:
      - name: code
        match_labels: []
        template: "code body for {{ issue.identifier }}"
      - name: life
        match_labels: ["life"]
        handoff_state: Done
        template: "life body for {{ issue.identifier }}"
    ---
    fallback body
    """)

    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, workflow} = Workflow.load(path)
    assert [code, life] = workflow.prompts
    assert code.name == "code"
    assert code.match_labels == []
    assert code.handoff_state == nil
    assert String.contains?(code.template, "code body")
    assert life.name == "life"
    assert life.match_labels == ["life"]
    assert life.handoff_state == "Done"
  end

  test "build_prompt/2 routes by label", %{} do
    workflow_file = Workflow.workflow_file_path()

    File.write!(workflow_file, """
    ---
    tracker:
      kind: linear
      project_slug: any
    prompts:
      - name: code
        match_labels: []
        template: "[code] {{ issue.identifier }}"
      - name: life
        match_labels: ["life"]
        handoff_state: Done
        template: "[life:{{ workflow.handoff_state }}] {{ issue.identifier }}"
    ---
    fallback
    """)

    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    code_issue = %Issue{id: "1", identifier: "T-1", labels: []}
    life_issue = %Issue{id: "2", identifier: "T-2", labels: ["life"]}

    assert PromptBuilder.build_prompt(life_issue) == "[life:Done] T-2"
    # No variant matches: PromptBuilder falls back to the body (`prompt_template`).
    assert PromptBuilder.build_prompt(code_issue) == "fallback"
  end

  test "build_prompt/2 keeps fallback when prompts is absent" do
    workflow_file = Workflow.workflow_file_path()

    File.write!(workflow_file, """
    ---
    tracker:
      kind: linear
      project_slug: any
    ---
    only body for {{ issue.identifier }}
    """)

    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    issue = %Issue{id: "3", identifier: "T-3", labels: ["life"]}
    assert PromptBuilder.build_prompt(issue) == "only body for T-3"
  end
end
