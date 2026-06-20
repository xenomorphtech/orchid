defmodule Orchid.OS.Command do
  @moduledoc false

  def run(command, args, opts \\ [])
      when is_binary(command) and is_list(args) and is_list(opts) do
    executable = resolve_executable!(command)
    port = Port.open({:spawn_executable, executable}, port_options(args, opts))
    reaper = start_reaper(self(), port)

    try do
      collect_output(port, "")
    after
      stop_reaper(reaper)
    end
  end

  defp resolve_executable!(command) do
    cond do
      String.contains?(command, "/") ->
        command

      executable = System.find_executable(command) ->
        executable

      true ->
        :erlang.error(:enoent)
    end
  end

  defp port_options(args, opts) do
    [:binary, :exit_status, {:args, args}]
    |> maybe_put_option(:stderr_to_stdout, opts[:stderr_to_stdout])
    |> maybe_put_option(:cd, opts[:cd])
    |> maybe_put_option(:env, port_env(opts[:env] || []))
  end

  defp maybe_put_option(options, _key, nil), do: options
  defp maybe_put_option(options, _key, false), do: options
  defp maybe_put_option(options, _key, []), do: options
  defp maybe_put_option(options, key, true), do: [key | options]
  defp maybe_put_option(options, key, value), do: [{key, value} | options]

  defp port_env(env) when is_map(env) do
    env |> Enum.to_list() |> port_env()
  end

  defp port_env(env) do
    Enum.map(env, fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end

  defp collect_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data)

      {^port, {:exit_status, status}} ->
        {acc, status}
    end
  end

  defp start_reaper(owner, port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) -> pid
        _ -> nil
      end

    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:stop, ^owner} ->
          Process.demonitor(ref, [:flush])
          :ok

        {:DOWN, ^ref, :process, ^owner, _reason} ->
          kill_os_pid(os_pid)
      end
    end)
  end

  defp stop_reaper(reaper), do: send(reaper, {:stop, self()})

  defp kill_os_pid(nil), do: :ok

  defp kill_os_pid(pid) when is_integer(pid) do
    signal(pid, "TERM")

    if alive?(pid) do
      Process.sleep(100)

      if alive?(pid) do
        signal(pid, "KILL")
      end
    end

    :ok
  end

  defp signal(pid, name) do
    case System.find_executable("kill") do
      nil ->
        :ok

      kill ->
        run_kill(kill, ["-#{name}", Integer.to_string(pid)])
    end
  end

  defp alive?(pid) do
    case System.find_executable("kill") do
      nil ->
        false

      kill ->
        {_output, status} = run_kill(kill, ["-0", Integer.to_string(pid)])
        status == 0
    end
  end

  defp run_kill(kill, args) do
    port =
      Port.open(
        {:spawn_executable, kill},
        [:binary, :exit_status, :stderr_to_stdout, {:args, args}]
      )

    collect_output(port, "")
  end
end
