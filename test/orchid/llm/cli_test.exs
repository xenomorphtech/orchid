defmodule Orchid.LLM.CLITest do
  use ExUnit.Case, async: false

  alias Orchid.LLM.CLI

  @tracked_env [
    "ORCHID_TEST_MODE",
    "ORCHID_TEST_OUTPUT",
    "ORCHID_TEST_PID_FILE"
  ]

  setup do
    dir = temp_path("orchid-fake-claude-")
    File.mkdir_p!(dir)

    script = Path.join(dir, "claude")
    File.write!(script, fake_claude_script())
    File.chmod!(script, 0o755)

    original_path = System.get_env("PATH") || ""
    original_env = Map.new(@tracked_env, fn key -> {key, System.get_env(key)} end)

    System.put_env("PATH", dir <> ":" <> original_path)

    on_exit(fn ->
      restore_env("PATH", original_path)

      Enum.each(original_env, fn {key, value} ->
        restore_env(key, value)
      end)

      File.rm_rf!(dir)
    end)

    :ok
  end

  test "chat returns output from the CLI port" do
    System.put_env("ORCHID_TEST_MODE", "print")
    System.put_env("ORCHID_TEST_OUTPUT", "hello from fake claude")

    assert {:ok, %{content: "hello from fake claude", tool_calls: nil}} =
             CLI.chat(%{}, context("hello"))
  end

  test "killing the caller tears down the CLI subprocess" do
    pid_file = temp_path("orchid-fake-claude-pid-", ".txt")

    System.put_env("ORCHID_TEST_MODE", "hang")
    System.put_env("ORCHID_TEST_PID_FILE", pid_file)

    parent = self()

    {caller, ref} =
      spawn_monitor(fn ->
        send(parent, :chat_started)
        CLI.chat(%{}, context("wait forever"))
      end)

    assert_receive :chat_started, 1_000

    os_pid = await_pid_file(pid_file)
    assert os_process_alive?(os_pid)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}, 5_000

    assert_eventually(fn -> not os_process_alive?(os_pid) end, 5_000)
  end

  defp context(message) do
    %{
      system: nil,
      messages: [%{role: :user, content: message}],
      objects: "",
      memory: %{}
    }
  end

  defp await_pid_file(path, deadline_ms \\ System.monotonic_time(:millisecond) + 5_000) do
    case File.read(path) do
      {:ok, raw} ->
        raw
        |> String.trim()
        |> String.to_integer()

      _ ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          flunk("Timed out waiting for fake claude pid file at #{path}")
        else
          Process.sleep(50)
          await_pid_file(path, deadline_ms)
        end
    end
  end

  defp os_process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp assert_eventually(fun, timeout_ms, interval_ms \\ 50) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline_ms, interval_ms, timeout_ms)
  end

  defp do_assert_eventually(fun, deadline_ms, interval_ms, timeout_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("Condition was not met within #{timeout_ms}ms")
      else
        Process.sleep(interval_ms)
        do_assert_eventually(fun, deadline_ms, interval_ms, timeout_ms)
      end
    end
  end

  defp temp_path(prefix, suffix \\ "") do
    Path.join(
      System.tmp_dir!(),
      "#{prefix}#{System.unique_integer([:positive])}#{suffix}"
    )
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp fake_claude_script do
    """
    #!/usr/bin/env node
    const fs = require("node:fs");

    const pidFile = process.env.ORCHID_TEST_PID_FILE;

    if (pidFile) {
      fs.writeFileSync(pidFile, String(process.pid));
    }

    if (process.env.ORCHID_TEST_MODE === "hang") {
      setInterval(() => {}, 1000);
    } else {
      process.stdout.write(process.env.ORCHID_TEST_OUTPUT || "ok");
      process.exit(0);
    }
    """
  end
end
