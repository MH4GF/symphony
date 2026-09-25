defmodule SymphonyElixir.ClaudeCode.WorkspaceTrust do
  @moduledoc """
  Persist workspace trust for `claude --bg` launches.

  Since Claude Code 2.1.280, `claude --bg` refuses to start in a directory that
  has not passed the workspace trust prompt and exits when not run
  interactively. Symphony creates a fresh clone per issue, so no workspace is
  ever trusted and every dispatch would fail with `Workspace not trusted`.

  Claude persists the accepted prompt as
  `projects[<workspace>].hasTrustDialogAccepted = true` in `~/.claude.json`
  (or `$CLAUDE_CONFIG_DIR/.claude.json`). The lookup walks parent directories
  only up to the git root, so trusting the workspace root directory is not
  enough; each clone needs its own entry. This module writes exactly what
  Claude would write on accept, before the runner launches the session.

  The config file is rewritten by every running Claude session. Writes here
  are read-modify-write with an atomic rename and skipped when the entry is
  already present, which keeps the clobber window as small as possible.
  """

  require Logger

  @trust_key "hasTrustDialogAccepted"

  @doc """
  Ensure `workspace` is recorded as trusted in the Claude config file.

  Returns `:ok` when the entry already existed or was written, otherwise
  `{:error, reason}`. Callers decide whether a failure blocks the launch.
  """
  @spec ensure_trusted(Path.t(), Path.t() | nil) :: :ok | {:error, term()}
  def ensure_trusted(workspace, config_path \\ nil) when is_binary(workspace) do
    key = Path.expand(workspace)
    path = config_path || default_config_path()

    with {:ok, config} <- read_config(path) do
      if trusted?(config, key) do
        :ok
      else
        write_config(path, put_trust(config, key))
      end
    end
  end

  @doc """
  Location of Claude's global config: `$CLAUDE_CONFIG_DIR/.claude.json` when
  the variable is set, otherwise `~/.claude.json`.
  """
  @spec default_config_path() :: Path.t()
  def default_config_path do
    case System.get_env("CLAUDE_CONFIG_DIR") do
      dir when is_binary(dir) and dir != "" -> Path.join(dir, ".claude.json")
      _ -> Path.join(System.user_home!(), ".claude.json")
    end
  end

  defp trusted?(config, key) do
    get_in(config, ["projects", key, @trust_key]) == true
  end

  defp put_trust(config, key) do
    projects = Map.get(config, "projects") || %{}
    project = Map.get(projects, key) || %{}
    Map.put(config, "projects", Map.put(projects, key, Map.put(project, @trust_key, true)))
  end

  defp read_config(path) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, _other} -> {:error, {:invalid_config, path}}
          {:error, reason} -> {:error, {:invalid_config, path, reason}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:read_failed, path, reason}}
    end
  end

  # Write to a sibling temp file and rename over the original so a concurrent
  # reader never sees a partial file. Mode 0600 matches what Claude uses.
  defp write_config(path, config) do
    tmp = "#{path}.symphony-#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, Jason.encode!(config)),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {:write_failed, path, reason}}
    end
  end
end
