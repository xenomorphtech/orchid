defmodule Orchid.Autonomy.SandboxReaper do
  @moduledoc """
  Reclaims Orchid Podman sandboxes whose owning BEAM process is gone.

  Each sandbox container and sandbox directory carries an owner identity made
  from the BEAM OS pid and `/proc/<pid>/stat` start time. That pair avoids PID
  reuse ambiguity when a later runner decides whether an old sandbox is live.
  """

  use GenServer
  require Logger

  alias Orchid.{Project, Sandbox}
  alias Orchid.OS.Command

  @default_interval_ms 30_000
  @container_prefix "orchid-project-"
  @owner_file "owner.json"
  @temp_data_prefix "orchid-real-goal-closure-"

  @label_sandbox "org.orchid.sandbox"
  @label_project_id "org.orchid.sandbox.project_id"
  @label_owner_run_id "org.orchid.sandbox.owner_run_id"
  @label_owner_pid "org.orchid.sandbox.owner_pid"
  @label_owner_start_time "org.orchid.sandbox.owner_start_time"
  @label_created_at "org.orchid.sandbox.created_at"

  @type sweep_report :: %{
          containers_reaped: [String.t()],
          containers_kept: [String.t()],
          dirs_reaped: [String.t()],
          dirs_kept: [String.t()],
          errors: [String.t()]
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    interval_ms =
      Keyword.get(
        opts,
        :interval_ms,
        Application.get_env(:orchid, :sandbox_reaper_interval_ms, @default_interval_ms)
      )

    log_report(:startup, sweep(:startup, include_current_owner: false))

    schedule_tick(interval_ms)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:tick, state) do
    log_report(:tick, sweep(:tick, include_current_owner: false))

    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  def handle_info({:EXIT, _port, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _from, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(reason, _state) do
    if shutdown_reason?(reason) do
      log_report(:shutdown, sweep(:shutdown, include_current_owner: true))
    end

    :ok
  end

  @doc """
  Returns the stable owner identity for this BEAM OS process.
  """
  def owner_identity do
    pid = System.pid()
    start_time = process_start_time(pid)
    start_part = start_time || "unknown"

    %{
      run_id: "orchid-run-#{pid}-#{start_part}",
      pid: pid,
      start_time: start_time
    }
  end

  @doc """
  Labels to apply to a newly-created sandbox container.
  """
  def container_labels(project_id) when is_binary(project_id) do
    owner = owner_identity()

    %{
      @label_sandbox => "true",
      @label_project_id => project_id,
      @label_owner_run_id => owner.run_id,
      @label_owner_pid => owner.pid,
      @label_owner_start_time => owner.start_time || "",
      @label_created_at => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Converts container label metadata into `podman run --label` arguments.
  """
  def podman_label_args(labels) when is_map(labels) do
    labels
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn {key, value} -> ["--label", "#{key}=#{value}"] end)
  end

  def podman_label_args(project_id) when is_binary(project_id) do
    project_id
    |> container_labels()
    |> podman_label_args()
  end

  @doc """
  Writes owner metadata beside the sandbox overlay directories.
  """
  def write_owner_metadata!(project_id, opts \\ []) when is_binary(project_id) do
    data_dir = Keyword.get(opts, :data_dir, Project.data_dir())
    labels = container_labels(project_id)
    dir = sandbox_dir(project_id, data_dir)

    File.mkdir_p!(dir)
    File.write!(owner_metadata_path(project_id, data_dir), Jason.encode!(labels, pretty: true))

    labels
  end

  @doc """
  Reaps one sandbox project unconditionally. Used by normal sandbox teardown.
  """
  def reap_project(project_id, opts \\ []) when is_binary(project_id) do
    data_dir = Keyword.get(opts, :data_dir, Project.data_dir())
    container_name = Sandbox.container_name(project_id)

    _ = remove_container(container_name)
    reap_sandbox_dir(project_id, data_dir: data_dir)
  end

  @doc """
  Removes a sandbox directory with `podman unshare rm -rf`.
  """
  def reap_sandbox_dir(project_id, opts \\ []) when is_binary(project_id) do
    data_dir = Keyword.get(opts, :data_dir, Project.data_dir())
    dir = sandbox_dir(project_id, data_dir)

    if safe_sandbox_dir?(dir, data_dir) do
      rm_rf_unshare(dir)
      remove_empty_sandbox_base(data_dir)
    else
      {:error, "refusing to remove unsafe sandbox dir #{inspect(dir)}"}
    end
  end

  @doc """
  Performs an orphan sweep and returns a deterministic report.
  """
  def sweep(opts) when is_list(opts), do: sweep(:manual, opts)

  def sweep(reason, opts) when is_list(opts) do
    include_current_owner? = Keyword.get(opts, :include_current_owner, false)
    data_dirs = Keyword.get(opts, :data_dirs, default_data_dirs())

    report = empty_report()

    case list_containers() do
      {:ok, containers} ->
        {report, kept_projects} =
          Enum.reduce(containers, {report, MapSet.new()}, fn container, {acc, kept} ->
            case maybe_reap_container(container, include_current_owner?) do
              {:reaped, name} ->
                {add_report(acc, :containers_reaped, name), kept}

              {:kept, name, project_id} ->
                kept = if project_id, do: MapSet.put(kept, project_id), else: kept
                {add_report(acc, :containers_kept, name), kept}

              {:error, message, project_id} ->
                kept = if project_id, do: MapSet.put(kept, project_id), else: kept
                {add_report(acc, :errors, message), kept}
            end
          end)

        sweep_dirs(data_dirs, kept_projects, include_current_owner?, true, report)

      {:error, message} ->
        report
        |> add_report(:errors, "podman container list failed during #{reason}: #{message}")
        |> then(&sweep_dirs(data_dirs, MapSet.new(), include_current_owner?, false, &1))
    end
  end

  def sandbox_dir(project_id, data_dir \\ Project.data_dir()) do
    Path.join([Path.expand(data_dir), "sandboxes", project_id])
  end

  def owner_metadata_path(project_id, data_dir \\ Project.data_dir()) do
    Path.join(sandbox_dir(project_id, data_dir), @owner_file)
  end

  defp schedule_tick(:infinity), do: :ok

  defp schedule_tick(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp schedule_tick(_interval_ms), do: :ok

  defp sweep_dirs(data_dirs, kept_projects, include_current_owner?, podman_list_ok?, report) do
    data_dirs
    |> Enum.uniq()
    |> Enum.reduce(report, fn data_dir, acc ->
      data_dir
      |> list_sandbox_dirs()
      |> Enum.reduce(acc, fn sandbox, dir_acc ->
        maybe_reap_dir(
          sandbox,
          kept_projects,
          include_current_owner?,
          podman_list_ok?,
          dir_acc
        )
      end)
    end)
  end

  defp maybe_reap_container(container, include_current_owner?) do
    project_id =
      Map.get(container.labels, @label_project_id) || project_id_from_name(container.name)

    case ownership_status(container.labels, include_current_owner?) do
      :orphan ->
        case remove_container(container.name) do
          :ok -> {:reaped, container.name}
          {:error, message} -> {:error, message, project_id}
        end

      :live ->
        {:kept, container.name, project_id}

      :unknown ->
        case container_running?(container.name) do
          false ->
            case remove_container(container.name) do
              :ok -> {:reaped, container.name}
              {:error, message} -> {:error, message, project_id}
            end

          _running_or_unknown ->
            {:kept, container.name, project_id}
        end
    end
  end

  defp maybe_reap_dir(sandbox, kept_projects, include_current_owner?, podman_list_ok?, report) do
    cond do
      MapSet.member?(kept_projects, sandbox.project_id) ->
        add_report(report, :dirs_kept, sandbox.path)

      not safe_sandbox_dir?(sandbox.path, sandbox.data_dir) ->
        add_report(
          report,
          :errors,
          "refusing to remove unsafe sandbox dir #{inspect(sandbox.path)}"
        )

      true ->
        case dir_ownership_status(sandbox, include_current_owner?) do
          :orphan ->
            reap_dir_into_report(report, sandbox)

          :live ->
            add_report(report, :dirs_kept, sandbox.path)

          :unknown when podman_list_ok? ->
            reap_dir_into_report(report, sandbox)

          :unknown ->
            add_report(report, :dirs_kept, sandbox.path)
        end
    end
  end

  defp reap_dir_into_report(report, sandbox) do
    case rm_rf_unshare(sandbox.path) do
      :ok ->
        remove_empty_sandbox_base(sandbox.data_dir)
        add_report(report, :dirs_reaped, sandbox.path)

      {:error, message} ->
        add_report(report, :errors, message)
    end
  end

  defp ownership_status(labels, include_current_owner?) when is_map(labels) do
    cond do
      current_owner?(labels) ->
        if include_current_owner?, do: :orphan, else: :live

      owner_labeled?(labels) ->
        if owner_alive?(labels), do: :live, else: :orphan

      Map.get(labels, @label_sandbox) == "true" ->
        :orphan

      true ->
        :unknown
    end
  end

  defp dir_ownership_status(sandbox, include_current_owner?) do
    case read_owner_metadata(sandbox) do
      {:ok, labels} -> ownership_status(labels, include_current_owner?)
      :missing -> :unknown
      {:error, message} -> {:error, message}
    end
    |> case do
      {:error, _message} -> :unknown
      status -> status
    end
  end

  defp current_owner?(labels) do
    owner = owner_identity()

    Map.get(labels, @label_owner_pid) == owner.pid and
      normalize_blank(Map.get(labels, @label_owner_start_time)) == owner.start_time
  end

  defp owner_labeled?(labels) do
    present?(Map.get(labels, @label_owner_pid)) and
      present?(Map.get(labels, @label_owner_start_time))
  end

  defp owner_alive?(labels) do
    pid = Map.get(labels, @label_owner_pid)
    expected_start_time = normalize_blank(Map.get(labels, @label_owner_start_time))

    case process_start_time(pid) do
      ^expected_start_time when not is_nil(expected_start_time) -> true
      _ -> false
    end
  end

  defp process_start_time(pid) when is_binary(pid) do
    stat_path = Path.join(["/proc", pid, "stat"])

    with {:ok, stat} <- File.read(stat_path),
         [_prefix, fields_text] <- String.split(stat, ") ", parts: 2),
         fields <- String.split(fields_text, " ", trim: true),
         start_time when is_binary(start_time) <- Enum.at(fields, 19) do
      start_time
    else
      _ -> nil
    end
  end

  defp process_start_time(_pid), do: nil

  defp list_containers do
    case podman(["ps", "-a", "--filter", "name=#{@container_prefix}", "--format", "{{.Names}}"]) do
      {output, 0} ->
        containers =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.starts_with?(&1, @container_prefix))
          |> Enum.uniq()
          |> Enum.map(&container_record/1)

        {:ok, containers}

      {output, code} ->
        {:error, "exit=#{code} output=#{String.trim(output)}"}
    end
  end

  defp container_record(name) do
    %{
      name: name,
      labels: inspect_labels(name)
    }
  end

  defp inspect_labels(name) do
    case podman(["inspect", "--format", "{{json .Config.Labels}}", name]) do
      {output, 0} ->
        output
        |> String.trim()
        |> decode_labels()

      _ ->
        %{}
    end
  end

  defp decode_labels(""), do: %{}
  defp decode_labels("null"), do: %{}
  defp decode_labels("<no value>"), do: %{}

  defp decode_labels(text) do
    case Jason.decode(text) do
      {:ok, labels} when is_map(labels) -> stringify_map(labels)
      _ -> %{}
    end
  end

  defp container_running?(name) do
    case podman(["inspect", "--format", "{{.State.Running}}", name]) do
      {"true\n", 0} -> true
      {"true", 0} -> true
      {"false\n", 0} -> false
      {"false", 0} -> false
      _ -> :unknown
    end
  end

  defp remove_container(name) do
    case podman(["rm", "-f", name]) do
      {_output, 0} ->
        :ok

      {output, code} ->
        {:error, "failed to remove container #{name}: exit=#{code} #{String.trim(output)}"}
    end
  end

  defp rm_rf_unshare(path) do
    case podman(["unshare", "rm", "-rf", path]) do
      {_output, 0} ->
        :ok

      {output, code} ->
        case File.rm_rf(path) do
          {:ok, _files} ->
            :ok

          {:error, file, reason} ->
            {:error,
             "failed to remove #{path} with podman unshare (exit=#{code} #{String.trim(output)}) " <>
               "and File.rm_rf failed at #{file}: #{inspect(reason)}"}
        end
    end
  end

  defp podman(args) do
    case System.find_executable("podman") do
      nil ->
        {"podman executable not found", 127}

      _path ->
        Command.run("podman", args, stderr_to_stdout: true)
    end
  rescue
    error -> {"#{Exception.message(error)}", 127}
  catch
    kind, reason -> {"#{kind}: #{inspect(reason)}", 127}
  end

  defp list_sandbox_dirs(data_dir) do
    base = sandbox_base(data_dir)

    case File.ls(base) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn entry ->
          path = Path.join(base, entry)
          %{project_id: entry, data_dir: data_dir, path: path}
        end)
        |> Enum.filter(&File.dir?(&1.path))

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("Sandbox reaper could not list #{base}: #{inspect(reason)}")
        []
    end
  end

  defp read_owner_metadata(sandbox) do
    path = Path.join(sandbox.path, @owner_file)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, labels} when is_map(labels) -> {:ok, stringify_map(labels)}
          {:error, reason} -> {:error, "invalid owner metadata #{path}: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, "could not read owner metadata #{path}: #{inspect(reason)}"}
    end
  end

  defp default_data_dirs do
    [Project.data_dir() | closure_temp_data_dirs()]
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp closure_temp_data_dirs do
    System.tmp_dir!()
    |> Path.join("#{@temp_data_prefix}*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
  end

  defp sandbox_base(data_dir), do: Path.join(Path.expand(data_dir), "sandboxes")

  defp safe_sandbox_dir?(path, data_dir) do
    base = sandbox_base(data_dir) |> Path.expand()
    expanded = Path.expand(path)
    String.starts_with?(expanded, base <> "/") and Path.basename(expanded) not in ["", "."]
  end

  defp remove_empty_sandbox_base(data_dir) do
    base = sandbox_base(data_dir)

    case File.rmdir(base) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp project_id_from_name(@container_prefix <> project_id), do: project_id
  defp project_id_from_name(_name), do: nil

  defp empty_report do
    %{
      containers_reaped: [],
      containers_kept: [],
      dirs_reaped: [],
      dirs_kept: [],
      errors: []
    }
  end

  defp add_report(report, key, value) do
    Map.update!(report, key, &[value | &1])
  end

  defp log_report(reason, report) do
    report = sort_report(report)

    if report.containers_reaped != [] or report.dirs_reaped != [] or report.errors != [] do
      Logger.info(
        "Sandbox reaper #{reason}: containers_reaped=#{length(report.containers_reaped)} " <>
          "dirs_reaped=#{length(report.dirs_reaped)} errors=#{length(report.errors)}"
      )

      Enum.each(report.errors, &Logger.warning("Sandbox reaper error: #{&1}"))
    end

    report
  end

  defp sort_report(report) do
    %{
      report
      | containers_reaped: Enum.sort(report.containers_reaped),
        containers_kept: Enum.sort(report.containers_kept),
        dirs_reaped: Enum.sort(report.dirs_reaped),
        dirs_kept: Enum.sort(report.dirs_kept),
        errors: Enum.sort(report.errors)
    }
  end

  defp shutdown_reason?(:normal), do: true
  defp shutdown_reason?(:shutdown), do: true
  defp shutdown_reason?({:shutdown, _reason}), do: true
  defp shutdown_reason?(_reason), do: false

  defp normalize_blank(nil), do: nil
  defp normalize_blank(""), do: nil
  defp normalize_blank(value), do: value

  defp present?(value), do: is_binary(value) and value != ""

  defp stringify_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_string(value)} end)
  end
end
