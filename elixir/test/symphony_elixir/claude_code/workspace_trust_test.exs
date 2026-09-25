defmodule SymphonyElixir.ClaudeCode.WorkspaceTrustTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ClaudeCode.WorkspaceTrust

  @workspace "/tmp/symphony-trust-test/GH-1"

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-trust-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{path: Path.join(dir, ".claude.json")}
  end

  test "creates the config and the project entry when the file is missing", %{path: path} do
    assert :ok = WorkspaceTrust.ensure_trusted(@workspace, path)

    assert %{"projects" => %{@workspace => %{"hasTrustDialogAccepted" => true}}} =
             path |> File.read!() |> Jason.decode!()
  end

  test "adds the entry while preserving unrelated config", %{path: path} do
    File.write!(
      path,
      Jason.encode!(%{
        "hasCompletedOnboarding" => true,
        "projects" => %{"/other" => %{"hasTrustDialogAccepted" => false, "allowedTools" => []}}
      })
    )

    assert :ok = WorkspaceTrust.ensure_trusted(@workspace, path)
    config = path |> File.read!() |> Jason.decode!()

    assert config["hasCompletedOnboarding"] == true
    assert config["projects"]["/other"] == %{"hasTrustDialogAccepted" => false, "allowedTools" => []}
    assert config["projects"][@workspace]["hasTrustDialogAccepted"] == true
  end

  test "flips an existing untrusted entry without dropping its other keys", %{path: path} do
    File.write!(
      path,
      Jason.encode!(%{"projects" => %{@workspace => %{"hasTrustDialogAccepted" => false, "lastCost" => 1.5}}})
    )

    assert :ok = WorkspaceTrust.ensure_trusted(@workspace, path)
    config = path |> File.read!() |> Jason.decode!()

    assert config["projects"][@workspace] == %{"hasTrustDialogAccepted" => true, "lastCost" => 1.5}
  end

  test "does not rewrite the file when already trusted", %{path: path} do
    raw = Jason.encode!(%{"projects" => %{@workspace => %{"hasTrustDialogAccepted" => true}}})
    File.write!(path, raw)
    %File.Stat{mtime: mtime} = File.stat!(path)

    assert :ok = WorkspaceTrust.ensure_trusted(@workspace, path)

    assert File.read!(path) == raw
    assert %File.Stat{mtime: ^mtime} = File.stat!(path)
  end

  test "expands the workspace path before using it as the key", %{path: path} do
    assert :ok = WorkspaceTrust.ensure_trusted("/tmp/symphony-trust-test/./GH-1/../GH-1", path)
    config = path |> File.read!() |> Jason.decode!()
    assert config["projects"][@workspace]["hasTrustDialogAccepted"] == true
  end

  test "returns an error and leaves a malformed file untouched", %{path: path} do
    File.write!(path, "{not json")

    assert {:error, {:invalid_config, ^path, _}} = WorkspaceTrust.ensure_trusted(@workspace, path)
    assert File.read!(path) == "{not json"
    assert Path.wildcard("#{path}.symphony-*.tmp") == []
  end

  test "rejects a config whose top level is not an object", %{path: path} do
    File.write!(path, "[]")

    assert {:error, {:invalid_config, ^path}} = WorkspaceTrust.ensure_trusted(@workspace, path)
    assert File.read!(path) == "[]"
  end

  test "returns a read error when the config path is not a regular file", %{path: path} do
    File.mkdir_p!(path)

    assert {:error, {:read_failed, ^path, :eisdir}} = WorkspaceTrust.ensure_trusted(@workspace, path)
  end

  test "returns a write error and leaves no temp file when the directory is read-only", %{path: path} do
    dir = Path.dirname(path)
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod(dir, 0o700) end)

    assert {:error, {:write_failed, ^path, :eacces}} = WorkspaceTrust.ensure_trusted(@workspace, path)
    assert Path.wildcard("#{path}.symphony-*.tmp") == []
  end

  describe "default_config_path/0" do
    setup do
      previous = System.get_env("CLAUDE_CONFIG_DIR")

      on_exit(fn ->
        if previous, do: System.put_env("CLAUDE_CONFIG_DIR", previous), else: System.delete_env("CLAUDE_CONFIG_DIR")
      end)

      :ok
    end

    test "honours CLAUDE_CONFIG_DIR" do
      System.put_env("CLAUDE_CONFIG_DIR", "/tmp/claude-config-dir")
      assert WorkspaceTrust.default_config_path() == "/tmp/claude-config-dir/.claude.json"
    end

    test "falls back to the home directory" do
      System.delete_env("CLAUDE_CONFIG_DIR")
      assert WorkspaceTrust.default_config_path() == Path.join(System.user_home!(), ".claude.json")
    end
  end

  test "writes the file with mode 0600", %{path: path} do
    assert :ok = WorkspaceTrust.ensure_trusted(@workspace, path)
    assert %File.Stat{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end
end
