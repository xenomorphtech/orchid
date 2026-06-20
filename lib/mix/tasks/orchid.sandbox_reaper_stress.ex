defmodule Mix.Tasks.Orchid.SandboxReaperStress do
  @moduledoc """
  Runs a deterministic Podman sandbox reaper stress test.

  The stress creates at least three real sandboxes. Two are normal lifecycle
  runs. One is created by a child BEAM that is killed with SIGKILL after the
  container is live; a fresh BEAM startup must reap that orphan.
  """

  use Mix.Task

  alias Orchid.Autonomy.{Runtime, SandboxReaper}
  alias Orchid.{Project, Projects, Sandbox}

  @shortdoc "Stress the Orchid sandbox reaper with a SIGKILL orphan"
  @default_runs 3
  @default_out Path.join(["priv", "autonomy", "sandbox_reaper_stress.json"])
  @container_prefix "orchid-project-"
  @poll_interval_ms 500

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          runs: :integer,
          out: :string,
          timeout_ms: :integer
        ]
      )

    reject_invalid_options!(invalid)

    runs = opts |> Keyword.get(:runs, @default_runs) |> validate_runs!()
    output_path = opts |> Keyword.get(:out, @default_out) |> validate_output_path!()
    timeout_ms = opts |> Keyword.get(:timeout_ms, 180_000) |> validate_timeout!()

    started_at = DateTime.utc_now()
    data_dir = Project.data_dir() |> Path.expand()

    Application.put_env(:orchid, :sandbox_reaper_interval_ms, :infinity)
    :ok = Runtime.ensure_started()

    baseline = leak_snapshot(data_dir)

    normal_samples =
      1..(runs - 1)
      |> Enum.map(fn index -> normal_run(index, data_dir, timeout_ms) end)

    kill_sample = sigkill_run(runs, data_dir, timeout_ms)
    fresh_sample = fresh_startup_sweep(data_dir, timeout_ms)
    final_snapshot = leak_snapshot(data_dir)

    report = %{
      started_at: DateTime.to_iso8601(started_at),
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      data_dir: data_dir,
      requested_runs: runs,
      normal_runs: normal_samples,
      sigkill_run: kill_sample,
      fresh_startup_sweep: fresh_sample,
      baseline: baseline,
      final: final_snapshot,
      criteria: %{
        runs_at_least_3: runs >= 3,
        sigkill_mid_run: kill_sample.killed == true,
        leaked_orphans_zero: final_snapshot.leaked_orphans == 0,
        sandbox_dirs_clean: final_snapshot.sandbox_dirs == []
      }
    }

    write_report!(report, output_path)

    unless report.criteria.leaked_orphans_zero and report.criteria.sandbox_dirs_clean do
      Mix.raise(
        "sandbox reaper stress leaked resources: " <>
          "containers=#{inspect(final_snapshot.containers)} " <>
          "sandbox_dirs=#{inspect(final_snapshot.sandbox_dirs)}"
      )
    end

    Mix.shell().info(
      "orchid.sandbox_reaper_stress: runs=#{runs} sigkill_project=#{kill_sample.project_id} " <>
        "leaked_orphans=#{final_snapshot.leaked_orphans} wrote #{output_path}"
    )
  end

  defp normal_run(index, data_dir, timeout_ms) do
    project_id = project_id("normal-#{index}")
    started = monotonic_ms()

    try do
      Project.ensure_dir(project_id)
      {:ok, _pid} = Projects.ensure_sandbox(project_id)
      :ok = wait_until(fn -> Sandbox.healthy?(project_id) end, timeout_ms)
      Projects.stop_sandbox(project_id)

      :ok =
        wait_until(
          fn -> not container_exists?(Sandbox.container_name(project_id)) end,
          timeout_ms
        )

      SandboxReaper.reap_project(project_id, data_dir: data_dir)

      %{
        index: index,
        project_id: project_id,
        container_name: Sandbox.container_name(project_id),
        status: :ok,
        duration_ms: monotonic_ms() - started
      }
    after
      Project.delete_dir(project_id)
    end
  end

  defp sigkill_run(index, data_dir, timeout_ms) do
    project_id = project_id("sigkill-#{index}")
    container_name = Sandbox.container_name(project_id)
    ready_file = Path.join(System.tmp_dir!(), "#{project_id}.ready")
    child_report = Path.join(System.tmp_dir!(), "#{project_id}.child.json")
    File.rm(ready_file)
    File.rm(child_report)

    started = monotonic_ms()
    port = start_child_sandbox(project_id, ready_file, child_report, data_dir)
    os_pid = port_os_pid(port)

    try do
      :ok =
        wait_until(
          fn -> File.exists?(ready_file) and container_exists?(container_name) end,
          timeout_ms
        )

      {_output, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
      exit_status = collect_port_exit(port, timeout_ms)

      %{
        index: index,
        project_id: project_id,
        container_name: container_name,
        child_os_pid: os_pid,
        killed: true,
        child_exit_status: exit_status,
        child_report: read_json_file(child_report),
        duration_ms: monotonic_ms() - started
      }
    after
      File.rm(ready_file)
    end
  end

  defp fresh_startup_sweep(data_dir, timeout_ms) do
    report_file = Path.join(System.tmp_dir!(), "orchid-sandbox-reaper-fresh-#{unique()}.json")
    code = fresh_sweep_code()

    try do
      {output, status} =
        run_mix(
          ["run", "--no-start", "-e", code],
          [
            {"ORCHID_STRESS_DATA_DIR", data_dir},
            {"ORCHID_STRESS_REPORT_FILE", report_file}
          ],
          timeout_ms
        )

      %{
        exit_status: status,
        output: output,
        report: read_json_file(report_file)
      }
    after
      File.rm(report_file)
    end
  end

  defp start_child_sandbox(project_id, ready_file, child_report, data_dir) do
    Port.open(
      {:spawn_executable, mix_executable()},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, File.cwd!()},
        {:args, ["run", "--no-start", "-e", child_sandbox_code()]},
        {:env,
         port_env([
           {"ORCHID_STRESS_PROJECT_ID", project_id},
           {"ORCHID_STRESS_READY_FILE", ready_file},
           {"ORCHID_STRESS_REPORT_FILE", child_report},
           {"ORCHID_STRESS_DATA_DIR", data_dir}
         ])}
      ]
    )
  end

  defp child_sandbox_code do
    """
    Application.put_env(:orchid, :sandbox_reaper_interval_ms, :infinity)
    Application.put_env(:orchid, :data_dir, System.fetch_env!("ORCHID_STRESS_DATA_DIR"))
    :ok = Orchid.Autonomy.Runtime.ensure_started()
    project_id = System.fetch_env!("ORCHID_STRESS_PROJECT_ID")
    ready_file = System.fetch_env!("ORCHID_STRESS_READY_FILE")
    report_file = System.fetch_env!("ORCHID_STRESS_REPORT_FILE")
    Orchid.Project.ensure_dir(project_id)
    {:ok, _pid} = Orchid.Projects.ensure_sandbox(project_id)
    report = %{
      project_id: project_id,
      container_name: Orchid.Sandbox.container_name(project_id),
      sandbox: Orchid.Sandbox.status(project_id),
      owner: Orchid.Autonomy.SandboxReaper.owner_identity()
    }
    File.write!(report_file, Jason.encode!(report, pretty: true))
    File.write!(ready_file, "ready\\n")
    Process.sleep(:infinity)
    """
  end

  defp fresh_sweep_code do
    """
    Application.put_env(:orchid, :sandbox_reaper_interval_ms, :infinity)
    Application.put_env(:orchid, :data_dir, System.fetch_env!("ORCHID_STRESS_DATA_DIR"))
    :ok = Orchid.Autonomy.Runtime.ensure_started()
    report = Orchid.Autonomy.SandboxReaper.sweep(:fresh_stress, include_current_owner: false)
    snapshot = %{
      reaper_report: report,
      leaked_orphans: System.cmd("sh", ["-c", "podman ps -a | grep -c orchid-project || true"], stderr_to_stdout: true) |> elem(0) |> String.trim()
    }
    File.write!(System.fetch_env!("ORCHID_STRESS_REPORT_FILE"), Jason.encode!(snapshot, pretty: true))
    """
  end

  defp collect_port_exit(port, timeout_ms) do
    receive do
      {^port, {:data, _data}} ->
        collect_port_exit(port, timeout_ms)

      {^port, {:exit_status, status}} ->
        status
    after
      timeout_ms ->
        :timeout
    end
  end

  defp run_mix(args, env, timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, mix_executable()},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:cd, File.cwd!()},
          {:args, args},
          {:env, port_env(env)}
        ]
      )

    os_pid = port_os_pid(port)
    collect_port_output(port, "", timeout_ms, os_pid)
  end

  defp collect_port_output(port, output, timeout_ms, os_pid) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, output <> data, timeout_ms, os_pid)

      {^port, {:exit_status, status}} ->
        {output, status}
    after
      timeout_ms ->
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        {output, :timeout}
    end
  end

  defp port_env(env) do
    Enum.map(env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> Mix.raise("could not determine child BEAM OS pid")
    end
  end

  defp leak_snapshot(data_dir) do
    containers = list_orchid_containers()
    sandbox_dirs = list_sandbox_dirs(data_dir)
    grep_count = podman_grep_count()

    %{
      leaked_orphans: grep_count,
      containers: containers,
      sandbox_dirs: sandbox_dirs,
      sandbox_dir_count: length(sandbox_dirs)
    }
  end

  defp list_orchid_containers do
    case System.cmd("podman", ["ps", "-a", "--format", "{{.Names}}"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, @container_prefix))
        |> Enum.sort()

      {_output, _status} ->
        []
    end
  end

  defp podman_grep_count do
    case System.cmd("sh", ["-c", "podman ps -a | grep -c orchid-project || true"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.trim()
        |> parse_non_negative_integer()

      {_output, _status} ->
        -1
    end
  end

  defp list_sandbox_dirs(data_dir) do
    base = Path.join(data_dir, "sandboxes")

    case File.ls(base) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(base, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort()

      {:error, :enoent} ->
        []
    end
  end

  defp container_exists?(container_name) do
    case System.cmd("podman", ["inspect", container_name], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = monotonic_ms() + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      monotonic_ms() >= deadline ->
        Mix.raise("timed out waiting for sandbox stress condition")

      true ->
        Process.sleep(@poll_interval_ms)
        do_wait_until(fun, deadline)
    end
  end

  defp write_report!(report, output_path) do
    output_path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(output_path, Jason.encode!(report, pretty: true))
  end

  defp read_json_file(path) do
    case File.read(path) do
      {:ok, content} -> Jason.decode!(content)
      {:error, :enoent} -> nil
    end
  end

  defp mix_executable do
    System.find_executable("mix") || Mix.raise("mix executable not found")
  end

  defp reject_invalid_options!([]), do: :ok

  defp reject_invalid_options!(invalid) do
    options = invalid |> Enum.map_join(", ", fn {option, _value} -> option end)
    Mix.raise("Invalid orchid.sandbox_reaper_stress option(s): #{options}")
  end

  defp validate_runs!(runs) when is_integer(runs) and runs >= 3, do: runs

  defp validate_runs!(runs),
    do: Mix.raise("--runs must be an integer >= 3, got: #{inspect(runs)}")

  defp validate_timeout!(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: timeout_ms

  defp validate_timeout!(timeout_ms) do
    Mix.raise("--timeout-ms must be a positive integer, got: #{inspect(timeout_ms)}")
  end

  defp validate_output_path!(path) when is_binary(path) do
    if String.trim(path) == "" do
      Mix.raise("--out must be a non-empty path")
    end

    path
  end

  defp validate_output_path!(path), do: Mix.raise("--out must be a path, got: #{inspect(path)}")

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> -1
    end
  end

  defp project_id(label) do
    "reaper-stress-#{label}-#{unique()}"
  end

  defp unique do
    :crypto.strong_rand_bytes(5) |> Base.url_encode64(padding: false)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
