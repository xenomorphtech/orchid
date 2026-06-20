defmodule Orchid.Autonomy.SandboxReaperTest do
  use ExUnit.Case, async: false

  alias Orchid.Autonomy.SandboxReaper

  @label_sandbox "org.orchid.sandbox"
  @label_project_id "org.orchid.sandbox.project_id"
  @label_owner_run_id "org.orchid.sandbox.owner_run_id"
  @label_owner_pid "org.orchid.sandbox.owner_pid"
  @label_owner_start_time "org.orchid.sandbox.owner_start_time"
  @label_created_at "org.orchid.sandbox.created_at"

  test "container labels include deterministic owner identity and creation time" do
    labels = SandboxReaper.container_labels("proj-labels")

    assert labels[@label_sandbox] == "true"
    assert labels[@label_project_id] == "proj-labels"
    assert labels[@label_owner_pid] == System.pid()
    assert String.starts_with?(labels[@label_owner_run_id], "orchid-run-#{System.pid()}-")
    assert labels[@label_owner_start_time] != ""
    assert {:ok, _created_at, _offset} = DateTime.from_iso8601(labels[@label_created_at])

    label_args = SandboxReaper.podman_label_args(labels)

    assert ["--label", "#{@label_project_id}=proj-labels"] -- label_args == []
    assert Enum.count(label_args, &(&1 == "--label")) == map_size(labels)
  end

  test "sweep keeps current owner sandboxes during startup and periodic passes" do
    project_id = "current-owner"
    data_dir = temp_data_dir()

    try do
      dir = SandboxReaper.sandbox_dir(project_id, data_dir)
      labels = SandboxReaper.write_owner_metadata!(project_id, data_dir: data_dir)

      File.mkdir_p!(Path.join(dir, "upper"))

      with_fake_podman([container(project_id, labels, true)], fn _state_dir ->
        report = SandboxReaper.sweep(data_dirs: [data_dir], include_current_owner: false)

        assert report.containers_kept == ["orchid-project-current-owner"]
        assert report.containers_reaped == []
        assert report.dirs_kept == [dir]
        assert report.dirs_reaped == []
        assert File.dir?(dir)
      end)
    after
      File.rm_rf(data_dir)
    end
  end

  test "shutdown sweep reaps current owner sandboxes" do
    project_id = "shutdown-owner"
    data_dir = temp_data_dir()

    try do
      dir = SandboxReaper.sandbox_dir(project_id, data_dir)
      labels = SandboxReaper.write_owner_metadata!(project_id, data_dir: data_dir)

      File.mkdir_p!(Path.join(dir, "upper"))

      with_fake_podman([container(project_id, labels, true)], fn state_dir ->
        report = SandboxReaper.sweep(data_dirs: [data_dir], include_current_owner: true)

        assert report.containers_reaped == ["orchid-project-shutdown-owner"]
        assert report.dirs_reaped == [dir]
        refute File.exists?(dir)

        calls = read_calls(state_dir)
        assert Enum.any?(calls, &(&1["argv"] == ["rm", "-f", "orchid-project-shutdown-owner"]))
        assert Enum.any?(calls, &(&1["argv"] == ["unshare", "rm", "-rf", dir]))
      end)
    after
      File.rm_rf(data_dir)
    end
  end

  test "startup sweep reaps dead owner containers and overlay dirs" do
    project_id = "dead-owner"
    data_dir = temp_data_dir()

    try do
      dir = SandboxReaper.sandbox_dir(project_id, data_dir)
      labels = dead_owner_labels(project_id)

      File.mkdir_p!(Path.join(dir, "upper"))
      File.write!(SandboxReaper.owner_metadata_path(project_id, data_dir), Jason.encode!(labels))

      with_fake_podman([container(project_id, labels, true)], fn state_dir ->
        report = SandboxReaper.sweep(data_dirs: [data_dir], include_current_owner: false)

        assert report.containers_reaped == ["orchid-project-dead-owner"]
        assert report.dirs_reaped == [dir]
        assert report.errors == []
        refute File.exists?(dir)
        assert read_containers(state_dir) == []
      end)
    after
      File.rm_rf(data_dir)
    end
  end

  test "sweep removes dead real-goal temp sandbox dirs even when data dir is kept" do
    project_id = "kept-temp"
    data_dir = Path.join(System.tmp_dir!(), "orchid-real-goal-closure-reaper-test-#{unique()}")

    try do
      dir = SandboxReaper.sandbox_dir(project_id, data_dir)

      File.mkdir_p!(Path.join(dir, "upper"))

      File.write!(
        SandboxReaper.owner_metadata_path(project_id, data_dir),
        Jason.encode!(dead_owner_labels(project_id))
      )

      with_fake_podman([], fn _state_dir ->
        report = SandboxReaper.sweep(data_dirs: [data_dir], include_current_owner: false)

        assert report.dirs_reaped == [dir]
        refute File.exists?(dir)
      end)
    after
      File.rm_rf(data_dir)
    end
  end

  defp container(project_id, labels, running) do
    %{
      name: "orchid-project-#{project_id}",
      labels: labels,
      running: running
    }
  end

  defp dead_owner_labels(project_id) do
    %{
      @label_sandbox => "true",
      @label_project_id => project_id,
      @label_owner_run_id => "orchid-run-dead",
      @label_owner_pid => "999999",
      @label_owner_start_time => "1",
      @label_created_at => "2026-06-20T00:00:00Z"
    }
  end

  defp with_fake_podman(containers, fun) do
    dir = Path.join(System.tmp_dir!(), "orchid-fake-podman-#{unique()}")
    File.mkdir_p!(dir)
    state_dir = Path.join(dir, "state")
    File.mkdir_p!(state_dir)

    File.write!(Path.join(state_dir, "containers.json"), Jason.encode!(containers))

    script = Path.join(dir, "podman")
    File.write!(script, fake_podman_script())
    File.chmod!(script, 0o755)

    original_path = System.get_env("PATH") || ""
    original_state_dir = System.get_env("FAKE_PODMAN_STATE_DIR")

    System.put_env("PATH", dir <> ":" <> original_path)
    System.put_env("FAKE_PODMAN_STATE_DIR", state_dir)

    try do
      fun.(state_dir)
    after
      restore_env("PATH", original_path)
      restore_env("FAKE_PODMAN_STATE_DIR", original_state_dir)
      File.rm_rf(dir)
    end
  end

  defp fake_podman_script do
    """
    #!/usr/bin/env node
    const fs = require("fs");
    const path = require("path");
    const stateDir = process.env.FAKE_PODMAN_STATE_DIR;
    const containersPath = path.join(stateDir, "containers.json");
    const callsPath = path.join(stateDir, "calls.json");
    const argv = process.argv.slice(2);

    function readJson(file, fallback) {
      if (!fs.existsSync(file)) return fallback;
      return JSON.parse(fs.readFileSync(file, "utf8"));
    }

    function writeJson(file, value) {
      fs.writeFileSync(file, JSON.stringify(value));
    }

    function containers() {
      return readJson(containersPath, []);
    }

    function saveContainers(value) {
      writeJson(containersPath, value);
    }

    function logCall() {
      const calls = readJson(callsPath, []);
      calls.push({ argv });
      writeJson(callsPath, calls);
    }

    logCall();

    if (argv[0] === "ps") {
      process.stdout.write(containers().map((container) => container.name).join("\\n"));
      process.exit(0);
    }

    if (argv[0] === "inspect") {
      const name = argv[argv.length - 1];
      const container = containers().find((item) => item.name === name);
      if (!container) {
        process.stderr.write("no such container\\n");
        process.exit(125);
      }

      const formatIndex = argv.indexOf("--format");
      const format = formatIndex >= 0 ? argv[formatIndex + 1] : "";

      if (format.includes(".Config.Labels")) {
        process.stdout.write(JSON.stringify(container.labels || {}));
      } else if (format.includes(".State.Running")) {
        process.stdout.write(container.running ? "true\\n" : "false\\n");
      }

      process.exit(0);
    }

    if (argv[0] === "rm") {
      const name = argv[argv.length - 1];
      saveContainers(containers().filter((container) => container.name !== name));
      process.exit(0);
    }

    if (argv[0] === "unshare" && argv[1] === "rm") {
      const target = argv[argv.length - 1];
      fs.rmSync(target, { recursive: true, force: true });
      process.exit(0);
    }

    process.stderr.write(`unsupported fake podman args: ${argv.join(" ")}\\n`);
    process.exit(2);
    """
  end

  defp read_calls(state_dir) do
    state_dir
    |> Path.join("calls.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp read_containers(state_dir) do
    state_dir
    |> Path.join("containers.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp temp_data_dir do
    Path.join(System.tmp_dir!(), "orchid-sandbox-reaper-test-#{unique()}")
  end

  defp unique do
    System.unique_integer([:positive]) |> Integer.to_string()
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
