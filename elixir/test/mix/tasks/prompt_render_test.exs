defmodule Mix.Tasks.Prompt.RenderTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias Mix.Tasks.Prompt.Render

  defmodule FakeLinearClient do
    alias SymphonyElixir.Tracker.Issue

    def fetch_issue_by_identifier("ABC-123" = identifier) do
      send(self(), {:fetched, identifier})

      {:ok,
       %Issue{
         id: "issue-uuid",
         identifier: identifier,
         title: "Fix the sandbox",
         state: "Todo",
         url: "https://linear.app/acme/issue/ABC-123/fix-the-sandbox"
       }}
    end

    def fetch_issue_by_identifier(_identifier), do: {:error, :not_found}
  end

  setup do
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    Mix.Task.reenable("prompt.render")

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, previous_client)
      end
    end)

    workflow_file = Path.join(Path.dirname(Workflow.workflow_file_path()), "RENDER_WORKFLOW.md")

    write_workflow_file!(workflow_file,
      prompt: "{{ issue.identifier }}: {{ issue.title }} ({{ issue.state }}) attempt={{ attempt }}"
    )

    %{workflow_file: workflow_file}
  end

  test "renders the workflow template for an issue URL", %{workflow_file: workflow_file} do
    output =
      capture_io(fn ->
        Render.run(["--workflow", workflow_file, "https://linear.app/acme/issue/abc-123/fix-the-sandbox"])
      end)

    assert output == "ABC-123: Fix the sandbox (Todo) attempt="
    assert_received {:fetched, "ABC-123"}
    assert Workflow.workflow_file_path() == workflow_file
  end

  test "accepts a bare identifier and an attempt number", %{workflow_file: workflow_file} do
    output = capture_io(fn -> Render.run(["-w", workflow_file, "ABC-123", "--attempt", "2"]) end)

    assert output == "ABC-123: Fix the sandbox (Todo) attempt=2"
  end

  test "raises when the issue cannot be fetched", %{workflow_file: workflow_file} do
    assert_raise Mix.Error, ~r/Failed to fetch Linear issue XYZ-9: :not_found/, fn ->
      Render.run(["--workflow", workflow_file, "XYZ-9"])
    end
  end

  test "rejects invalid arguments", %{workflow_file: workflow_file} do
    assert_raise Mix.Error, ~r/Missing required --workflow/, fn -> Render.run(["ABC-123"]) end
    assert_raise Mix.Error, ~r/Invalid option/, fn -> Render.run(["--bogus", "ABC-123"]) end
    assert_raise Mix.Error, ~r/Expected exactly one/, fn -> Render.run(["--workflow", workflow_file]) end

    assert_raise Mix.Error, ~r/Could not find a Linear issue identifier/, fn ->
      Render.run(["--workflow", workflow_file, "https://example.com/nope"])
    end
  end

  test "prints usage with --help" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Render.run(["--help"])

    assert_received {:mix_shell, :info, [usage]}
    assert usage =~ "mix prompt.render"
  end
end
