defmodule Orchid.Sandbox do
  @moduledoc """
  Sandbox — one Podman container per project.
  GenServer manages container lifecycle (start/stop/reset).
  Data operations (exec, read, write, etc.) bypass GenServer entirely —
  they run podman exec directly, so long commands never block other operations.
  """
  use GenServer
  require Logger

  alias Orchid.{Project, Sandbox.Overlay}

  defstruct [
    :project_id,
    :container_name,
    :lower_path,
    :upper_path,
    :work_path,
    :merged_path,
    :overlay_method,
    :image,
    :status
  ]

  # ── Deterministic path helpers (no GenServer needed) ──

  def container_name(project_id), do: "orchid-project-#{project_id}"

  defp paths(project_id) do
    data_dir = Project.data_dir() |> Path.expand()
    lower = Project.files_path(project_id) |> Path.expand()
    base = Path.join([data_dir, "sandboxes", project_id])

    %{
      lower: lower,
      upper: Path.join(base, "upper"),
      work: Path.join(base, "work"),
      merged: Path.join(base, "merged")
    }
  end

  defp overlay_method(project_id) do
    case Registry.lookup(Orchid.Registry, {:sandbox, project_id}) do
      [{_pid, method}] -> method
      [] -> nil
    end
  end

  # ── Client API: Lifecycle (goes through GenServer) ──

  def start_link(project_id) do
    GenServer.start_link(__MODULE__, project_id,
      name: {:via, Registry, {Orchid.Registry, {:sandbox, project_id}}}
    )
  end

  def child_spec(project_id) do
    %{
      id: {__MODULE__, project_id},
      start: {__MODULE__, :start_link, [project_id]},
      restart: :temporary
    }
  end

  def reset(project_id) do
    case Registry.lookup(Orchid.Registry, {:sandbox, project_id}) do
      [{pid, _}] -> GenServer.call(pid, :reset, 120_000)
      [] -> {:error, :sandbox_not_found}
    end
  end

  def stop(project_id) do
    case Registry.lookup(Orchid.Registry, {:sandbox, project_id}) do
      [{pid, _}] -> GenServer.stop(pid)
      [] -> :ok
    end
  end

  def status(project_id) do
    case Registry.lookup(Orchid.Registry, {:sandbox, project_id}) do
      [{_pid, method}] ->
        running = container_running?(container_name(project_id))

        %{
          status:
            cond do
              is_nil(method) -> :starting
              running -> :ready
              true -> :error
            end,
          container_name: container_name(project_id),
          overlay_method: method,
          running: running
        }

      [] ->
        nil
    end
  end

  def healthy?(project_id) do
    case Registry.lookup(Orchid.Registry, {:sandbox, project_id}) do
      [{_pid, method}] when not is_nil(method) ->
        container_running?(container_name(project_id))

      _ ->
        false
    end
  end

  # ── Client API: Data operations (bypass GenServer) ──

  def exec(project_id, command, opts \\ [])

  def exec(_project_id, command, _opts) when not is_binary(command) do
    {:error, {:invalid_command, command}}
  end

  def exec(_project_id, command, _opts) when is_binary(command) and byte_size(command) == 0 do
    {:error, :empty_command}
  end

  def exec(project_id, command, opts) do
    if String.trim(command) == "" do
      {:error, :empty_command}
    else
      do_exec(project_id, command, opts)
    end
  end

  defp do_exec(project_id, command, opts) do
    case overlay_method(project_id) do
      nil -> {:error, :sandbox_not_found}
      _method -> podman_exec(container_name(project_id), command, opts[:timeout] || 30_000)
    end
  end

  def read_file(project_id, path) do
    case overlay_method(project_id) do
      nil ->
        {:error, :sandbox_not_found}

      :overlay ->
        podman_exec(container_name(project_id), "cat #{escape(path)}")

      :union ->
        p = paths(project_id)
        rel = workspace_relative(path)

        case Overlay.union_read(rel, p.upper, p.lower) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, "Failed to read #{path}: #{reason}"}
        end
    end
  end

  def write_file(project_id, path, content) do
    case overlay_method(project_id) do
      nil ->
        {:error, :sandbox_not_found}

      :overlay ->
        podman_exec_stdin(
          container_name(project_id),
          "mkdir -p $(dirname #{escape(path)}) && cat > #{escape(path)}",
          content
        )

      :union ->
        p = paths(project_id)
        rel = workspace_relative(path)

        case Overlay.union_write(rel, content, p.upper) do
          :ok -> {:ok, "Written to #{path}"}
          {:error, reason} -> {:error, "Failed to write #{path}: #{reason}"}
        end
    end
  end

  def edit_file(project_id, path, old_string, new_string) do
    with {:ok, content} <- read_file(project_id, path) do
      if String.contains?(content, old_string) do
        count = length(String.split(content, old_string)) - 1

        if count > 1 do
          {:error, "old_string appears #{count} times - must be unique. Add more context."}
        else
          new_content = String.replace(content, old_string, new_string, global: false)

          case write_file(project_id, path, new_content) do
            {:ok, _} -> {:ok, "Successfully edited #{path}"}
            error -> error
          end
        end
      else
        {:error, "old_string not found in #{path}"}
      end
    end
  end

  def list_files(project_id, path \\ "/workspace") do
    case overlay_method(project_id) do
      nil ->
        {:error, :sandbox_not_found}

      :overlay ->
        podman_exec(container_name(project_id), "ls -la #{escape(path)}")

      :union ->
        p = paths(project_id)
        rel = workspace_relative(path)
        Overlay.union_list(rel, p.upper, p.lower)
    end
  end

  def grep_files(project_id, pattern, path \\ "/workspace", opts \\ []) do
    case overlay_method(project_id) do
      nil ->
        {:error, :sandbox_not_found}

      :overlay ->
        glob = opts[:glob]
        cmd = "rg -n --no-heading #{escape(pattern)} #{escape(path)}"
        cmd = if glob, do: cmd <> " --glob #{escape(glob)}", else: cmd
        podman_exec(container_name(project_id), cmd)

      :union ->
        p = paths(project_id)
        rel = workspace_relative(path)
        Overlay.union_grep(pattern, rel, p.upper, p.lower, opts)
    end
  end

  # ── GenServer callbacks ──

  @impl true
  def init(project_id) do
    p = paths(project_id)

    File.mkdir_p!(p.upper)
    File.mkdir_p!(p.work)
    File.mkdir_p!(p.merged)
    Project.ensure_dir(project_id)

    image = get_image()
    cname = container_name(project_id)

    state = %__MODULE__{
      project_id: project_id,
      container_name: cname,
      lower_path: p.lower,
      upper_path: p.upper,
      work_path: p.work,
      merged_path: p.merged,
      image: image,
      overlay_method: nil,
      status: :starting
    }

    state = start_container(state)
    # Store overlay_method in Registry value so data ops can read it without GenServer
    Registry.update_value(Orchid.Registry, {:sandbox, project_id}, fn _ ->
      state.overlay_method
    end)

    {:ok, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    destroy_container(state)
    new_state = start_container(%{state | status: :starting, image: get_image()})

    Registry.update_value(Orchid.Registry, {:sandbox, state.project_id}, fn _ ->
      new_state.overlay_method
    end)

    {:reply, {:ok, %{status: new_state.status}}, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    destroy_container(state)
    :ok
  end

  # ── Private: Container lifecycle ──

  defp get_image do
    Orchid.Object.get_fact_value("sandbox_image") || "orchid-sandbox:latest"
  end

  defp claude_mounts do
    home = System.user_home!()
    claude_bin = Path.join([home, ".local", "share", "claude", "versions"])

    claude_path =
      case File.read_link(Path.join([home, ".local", "bin", "claude"])) do
        {:ok, target} ->
          target

        _ ->
          case File.ls(claude_bin) do
            {:ok, versions} ->
              versions |> Enum.sort(:desc) |> List.first() |> then(&Path.join(claude_bin, &1))

            _ ->
              nil
          end
      end

    claude_dir = Path.join([home, ".claude"])

    mounts = []

    mounts =
      if claude_path && File.exists?(claude_path),
        do: mounts ++ ["-v", "#{claude_path}:/usr/local/bin/claude:ro"],
        else: mounts

    mounts =
      if File.dir?(claude_dir),
        do: mounts ++ ["-v", "#{claude_dir}:/tmp/.claude-host:ro"],
        else: mounts

    mounts
  end

  defp codex_mounts do
    home = System.user_home!()
    codex_home = System.get_env("CODEX_HOME") || Path.join(home, ".codex")
    codex_bin_path = System.find_executable("codex")
    codex_pkg_path = codex_package_path(codex_bin_path)
    codex_bridge_dir = Orchid.LLM.Codex.sdk_bridge_dir() |> Path.expand()
    container_bridge_dir = Orchid.LLM.Codex.container_bridge_dir()

    mounts = []

    mounts =
      if codex_pkg_path && File.dir?(codex_pkg_path),
        do: mounts ++ ["-v", "#{codex_pkg_path}:/usr/local/lib/node_modules/@openai/codex:ro"],
        else: mounts

    mounts =
      if File.dir?(codex_home),
        do: mounts ++ ["-v", "#{codex_home}:/tmp/.codex-host:ro"],
        else: mounts

    mounts =
      if File.dir?(codex_bridge_dir),
        do: mounts ++ ["-v", "#{codex_bridge_dir}:#{container_bridge_dir}:ro"],
        else: mounts

    mounts
  end

  defp codex_package_path(nil), do: nil

  defp codex_package_path(codex_bin_path) do
    case File.read_link(codex_bin_path) do
      {:ok, target} ->
        target
        |> Path.expand(Path.dirname(codex_bin_path))
        |> Path.dirname()
        |> Path.dirname()

      _ ->
        case System.cmd("sh", ["-c", "readlink -f #{escape(codex_bin_path)}"],
               stderr_to_stdout: true
             ) do
          {resolved, 0} ->
            resolved
            |> String.trim()
            |> Path.dirname()
            |> Path.dirname()

          _ ->
            nil
        end
    end
  end

  defp start_container(state) do
    # Prefer the stable bind-mount fallback. fuse-overlayfs mode has shown
    # cross-device-link write failures for normal mkdir/touch operations.
    case try_fallback_container(state) do
      {:ok, new_state} ->
        Logger.info(
          "Sandbox project-#{state.project_id}: fallback container started (union mode)"
        )

        new_state

      {:error, reason} ->
        Logger.warning(
          "Sandbox project-#{state.project_id}: fallback failed (#{reason}), trying overlay"
        )

        case try_overlay_container(state) do
          {:ok, new_state} ->
            Logger.info("Sandbox project-#{state.project_id}: overlay container started")
            new_state

          {:error, reason2} ->
            Logger.error(
              "Sandbox project-#{state.project_id}: all container methods failed: #{reason2}"
            )

            %{state | status: :error, overlay_method: :union}
        end
    end
  end

  defp dns_args do
    nameservers =
      ["/run/systemd/resolve/resolv.conf", "/etc/resolv.conf"]
      |> Enum.find_value([], &read_nameservers/1)
      |> Enum.reject(&(&1 in ["127.0.0.53", "127.0.0.1", "::1"]))
      |> Enum.filter(&ipv4?/1)
      |> Enum.uniq()
      |> Enum.take(3)

    nameservers =
      if nameservers == [] do
        # Conservative public fallback when host resolver info is unavailable.
        ["1.1.1.1", "8.8.8.8"]
      else
        nameservers
      end

    Enum.flat_map(nameservers, fn ns -> ["--dns", ns] end)
  end

  defp read_nameservers(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "nameserver "))
      |> Enum.map(fn line ->
        line |> String.replace_prefix("nameserver ", "") |> String.trim()
      end)
      |> case do
        [] -> nil
        list -> list
      end
    else
      nil
    end
  end

  defp ipv4?(ip) do
    case String.split(ip, ".", parts: 4) do
      [a, b, c, d] ->
        Enum.all?([a, b, c, d], fn part ->
          case Integer.parse(part) do
            {n, ""} -> n >= 0 and n <= 255
            _ -> false
          end
        end)

      _ ->
        false
    end
  end

  defp try_overlay_container(state) do
    System.cmd("podman", ["rm", "-f", state.container_name], stderr_to_stdout: true)

    args =
      [
        "run",
        "-d",
        "--name",
        state.container_name,
        "--cap-add=SYS_ADMIN",
        "--device",
        "/dev/fuse",
        "-v",
        "#{state.lower_path}:/workspace_lower:ro",
        "-v",
        "#{state.upper_path}:/workspace_upper",
        "-v",
        "#{state.work_path}:/workspace_work"
      ] ++
        dns_args() ++
        claude_mounts() ++
        codex_mounts() ++
        [
          state.image,
          "sh",
          "-c",
          "sudo mkdir -p /workspace && sudo fuse-overlayfs -o lowerdir=/workspace_lower,upperdir=/workspace_upper,workdir=/workspace_work /workspace && sudo chown agent:agent /workspace && " <>
            "if [ -d /usr/local/lib/node_modules/@openai/codex ]; then sudo ln -sf /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex; fi && " <>
            "if [ -d /tmp/.claude-host ]; then mkdir -p /home/agent/.claude && sudo cp /tmp/.claude-host/.credentials.json /tmp/.claude-host/settings.json /home/agent/.claude/ 2>/dev/null; sudo chown -R agent:agent /home/agent/.claude; fi && " <>
            "if [ -d /tmp/.codex-host ]; then mkdir -p /home/agent/.codex && sudo cp -r /tmp/.codex-host/* /home/agent/.codex/ 2>/dev/null; sudo chown -R agent:agent /home/agent/.codex; fi && " <>
            "exec sleep infinity"
        ]

    case System.cmd("podman", args, stderr_to_stdout: true) do
      {_output, 0} ->
        case wait_for_container(state.container_name, 10) do
          :running ->
            {:ok, %{state | status: :ready, overlay_method: :overlay}}

          :exited ->
            System.cmd("podman", ["rm", "-f", state.container_name], stderr_to_stdout: true)
            {:error, "container exited (overlay mount likely failed)"}
        end

      {output, _code} ->
        {:error, "podman run failed: #{String.trim(output)}"}
    end
  end

  defp try_fallback_container(state) do
    System.cmd("podman", ["rm", "-f", state.container_name], stderr_to_stdout: true)

    args =
      [
        "run",
        "-d",
        "--name",
        state.container_name,
        "-v",
        "#{state.lower_path}:/workspace_lower:ro",
        "-v",
        "#{state.upper_path}:/workspace:rw"
      ] ++
        dns_args() ++
        claude_mounts() ++
        codex_mounts() ++
        [
          state.image,
          "sh",
          "-c",
          # Seed fallback workspace with lower-layer snapshot so workers can read project files.
          "mkdir -p /workspace && sudo chown -R agent:agent /workspace && " <>
            "if [ -d /workspace_lower ]; then cp -a /workspace_lower/. /workspace/ 2>/dev/null || true; fi && " <>
            "if [ -d /usr/local/lib/node_modules/@openai/codex ]; then sudo ln -sf /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex; fi && " <>
            "if [ -d /tmp/.claude-host ]; then mkdir -p /home/agent/.claude && sudo cp /tmp/.claude-host/.credentials.json /tmp/.claude-host/settings.json /home/agent/.claude/ 2>/dev/null; sudo chown -R agent:agent /home/agent/.claude; fi && " <>
            "if [ -d /tmp/.codex-host ]; then mkdir -p /home/agent/.codex && sudo cp -r /tmp/.codex-host/* /home/agent/.codex/ 2>/dev/null; sudo chown -R agent:agent /home/agent/.codex; fi && " <>
            "exec sleep infinity"
        ]

    case System.cmd("podman", args, stderr_to_stdout: true) do
      {_output, 0} ->
        case wait_for_container(state.container_name, 10) do
          :running ->
            {:ok, %{state | status: :ready, overlay_method: :union}}

          :exited ->
            System.cmd("podman", ["rm", "-f", state.container_name], stderr_to_stdout: true)
            {:error, "container exited (fallback mode startup failed)"}
        end

      {output, _code} ->
        {:error, "podman fallback failed: #{String.trim(output)}"}
    end
  end

  defp wait_for_container(container_name, retries) when retries > 0 do
    Process.sleep(1_000)

    case System.cmd("podman", ["inspect", "--format", "{{.State.Running}}", container_name],
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> :running
      {"false\n", 0} -> :exited
      _ when retries > 1 -> wait_for_container(container_name, retries - 1)
      _ -> :exited
    end
  end

  defp destroy_container(state) do
    System.cmd("podman", ["rm", "-f", state.container_name], stderr_to_stdout: true)
  end

  # ── Private: Command execution (standalone, no GenServer) ──

  defp podman_exec(cname, command, timeout \\ 30_000) do
    task =
      Task.async(fn ->
        System.cmd(
          "podman",
          [
            "exec",
            "-w",
            "/workspace",
            cname,
            "sh",
            "-c",
            command
          ],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, code}} -> {:error, "Exit code #{code}:\n#{output}"}
      nil -> {:error, "Command timed out after #{timeout}ms"}
    end
  end

  defp podman_exec_stdin(cname, command, stdin_data) do
    tmpfile = Path.join(System.tmp_dir!(), "orchid-stdin-#{:erlang.unique_integer([:positive])}")
    File.write!(tmpfile, stdin_data)

    try do
      args = ["exec", "-i", "-w", "/workspace", cname, "sh", "-c", command]

      port =
        Port.open(
          {:spawn_executable, System.find_executable("sh")},
          [
            :binary,
            :exit_status,
            args: ["-c", "cat #{escape(tmpfile)} | podman #{Enum.map_join(args, " ", &escape/1)}"]
          ]
        )

      collect_port_output(port, "")
    after
      File.rm(tmpfile)
    end
  end

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, acc <> data)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, code}} ->
        {:error, "Exit code #{code}:\n#{acc}"}
    after
      300_000 ->
        try do
          Port.close(port)
        catch
          _, _ -> :ok
        end

        {:error, "Timed out waiting for command"}
    end
  end

  defp workspace_relative(path) do
    path
    |> String.replace_prefix("/workspace/", "")
    |> String.replace_prefix("/workspace", "")
    |> then(fn
      "" -> "."
      p -> p
    end)
  end

  defp escape(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  defp container_running?(container_name) when is_binary(container_name) do
    case System.cmd("podman", ["inspect", "--format", "{{.State.Running}}", container_name],
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _ -> false
    end
  end
end
