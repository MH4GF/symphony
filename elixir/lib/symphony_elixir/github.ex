defmodule SymphonyElixir.GitHub do
  @moduledoc """
  Reads pull request state for a workspace branch through the `gh` CLI.
  """

  @json_fields "number,url,state,mergeable,headRefOid"
  @no_pull_request_marker "no pull requests found"
  @max_error_output_bytes 1_000

  @type pull_request :: %{
          number: pos_integer(),
          url: String.t(),
          state: String.t(),
          mergeable: String.t(),
          head_oid: String.t()
        }

  @doc """
  Returns the pull request associated with the branch checked out in `workspace`.

  Resolves the repository and branch the same way `gh pr view` does when run
  inside the workspace, so it works regardless of how the branch was named.
  """
  @spec pull_request_for_workspace(Path.t(), timeout()) :: {:ok, pull_request()} | {:error, term()}
  def pull_request_for_workspace(workspace, timeout_ms)
      when is_binary(workspace) and is_integer(timeout_ms) do
    with {:ok, executable} <- executable(),
         {:ok, output} <- run(executable, workspace, timeout_ms),
         {:ok, payload} <- decode(output) do
      build(payload)
    end
  end

  defp executable do
    case System.find_executable("gh") do
      nil -> {:error, :gh_not_found}
      executable -> {:ok, executable}
    end
  end

  defp run(executable, workspace, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd(executable, ["pr", "view", "--json", @json_fields],
          cd: workspace,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, status}} ->
        {:error, gh_failure_reason(output, status)}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:gh_timeout, timeout_ms}}
    end
  end

  defp gh_failure_reason(output, status) do
    case String.contains?(String.downcase(output), @no_pull_request_marker) do
      true -> :no_pull_request
      false -> {:gh_failed, status, truncate(output)}
    end
  end

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _payload} -> {:error, :gh_unexpected_payload}
      {:error, error} -> {:error, {:gh_invalid_json, Exception.message(error)}}
    end
  end

  defp build(payload) do
    with number when is_integer(number) <- Map.get(payload, "number"),
         url when is_binary(url) <- Map.get(payload, "url"),
         state when is_binary(state) <- Map.get(payload, "state"),
         mergeable when is_binary(mergeable) <- Map.get(payload, "mergeable"),
         head_oid when is_binary(head_oid) <- Map.get(payload, "headRefOid") do
      {:ok, %{number: number, url: url, state: state, mergeable: mergeable, head_oid: head_oid}}
    else
      _unexpected -> {:error, :gh_unexpected_payload}
    end
  end

  defp truncate(output) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= @max_error_output_bytes do
      true -> binary_output
      false -> binary_part(binary_output, 0, @max_error_output_bytes) <> "... (truncated)"
    end
  end
end
