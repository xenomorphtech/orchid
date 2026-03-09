defmodule Orchid.LLM.CodexTest do
  use ExUnit.Case, async: false

  alias Orchid.LLM.Codex

  @runner Path.expand("../../support/codex_runner_echo.mjs", __DIR__)

  setup do
    original_runner = System.get_env("ORCHID_CODEX_RUNNER_PATH")
    System.put_env("ORCHID_CODEX_RUNNER_PATH", @runner)

    on_exit(fn ->
      restore_env("ORCHID_CODEX_RUNNER_PATH", original_runner)
    end)

    :ok
  end

  test "host workers build the expected SDK request" do
    project_id = "codex-host-test"
    {:ok, _} = Orchid.Project.ensure_dir(project_id)

    {:ok, %{content: content, tool_calls: nil}} =
      Codex.chat(
        %{
          provider: :codex,
          model: :gpt54,
          model_reasoning_effort: "high",
          project_id: project_id,
          execution_mode: :host
        },
        context("hello")
      )

    echoed = Jason.decode!(content)
    request = echoed["request"]

    assert request["model"] == "gpt-5.4"
    assert request["modelReasoningEffort"] == "high"
    refute Map.has_key?(request, "approvalPolicy")
    assert request["sandboxMode"] == "workspace-write"
    assert request["skipGitRepoCheck"] == false
    assert request["workingDirectory"] == Path.expand(Orchid.Project.files_path(project_id))
  end

  test "orchestrators disable the shell tool through SDK config overrides" do
    project_id = "codex-orchestrator-test"
    {:ok, _} = Orchid.Project.ensure_dir(project_id)

    {:ok, %{content: content, tool_calls: nil}} =
      Codex.chat(
        %{
          provider: :codex,
          model: :gpt54,
          project_id: project_id,
          execution_mode: :host,
          use_orchid_tools: true,
          agent_id: "agent-123"
        },
        context("plan this")
      )

    echoed = Jason.decode!(content)
    request = echoed["request"]
    env = echoed["env"]

    assert request["configOverrides"]["features"]["shell_tool"] == false
    assert request["workingDirectory"] == Path.expand(Orchid.Project.files_path(project_id))
    assert env["CODEX_HOME"] =~ "orchid-codex-"
    assert File.exists?(Path.join(env["CODEX_HOME"], "config.toml"))
  end

  test "vm orchestrators execute through podman and anchor to /workspace" do
    project_id = "codex-vm-orchestrator-test"
    {:ok, _} = Orchid.Project.ensure_dir(project_id)

    with_fake_podman(fn ->
      {:ok, %{content: content, tool_calls: nil}} =
        Codex.chat(
          %{
            provider: :codex,
            model: :gpt54,
            project_id: project_id,
            use_orchid_tools: true,
            agent_id: "agent-456"
          },
          context("plan this in the vm")
        )

      echoed = Jason.decode!(content)
      request = echoed["request"]
      argv = echoed["argv"]
      calls = echoed["calls"]
      config_toml = echoed["configToml"]

      assert request["approvalPolicy"] == "never"
      assert request["sandboxMode"] == "danger-full-access"
      assert request["skipGitRepoCheck"] == true
      assert request["workingDirectory"] == "/workspace"
      assert request["configOverrides"]["features"]["shell_tool"] == false

      assert Enum.map(calls, &hd(&1["argv"])) == ["cp", "cp", "exec"]
      assert config_toml =~ ~s([mcp_servers.orchid])
      assert config_toml =~ ~s(command = "node")
      assert config_toml =~ "mcp_stdio_proxy.mjs"
      assert config_toml =~ ~s([projects."/workspace"])

      assert normalize_codex_home_prefix(Enum.take(argv, 9)) == [
               "exec",
               "-w",
               "/workspace",
               "-e",
               "HOME=/home/agent",
               "-e",
               "CODEX_HOME=/tmp/orchid-codex-home-",
               "-e",
               "ORCHID_CODEX_CLI_PATH=/usr/local/bin/codex"
             ]
    end)
  end

  test "vm workers execute through podman with the container bridge path" do
    project_id = "codex-vm-test"
    {:ok, _} = Orchid.Project.ensure_dir(project_id)

    with_fake_podman(fn ->
      {:ok, %{content: content, tool_calls: nil}} =
        Codex.chat(
          %{
            provider: :codex,
            model: :gpt54,
            project_id: project_id
          },
          context("build it")
        )

      echoed = Jason.decode!(content)
      request = echoed["request"]
      argv = echoed["argv"]
      calls = echoed["calls"]
      config_toml = echoed["configToml"]

      assert request["approvalPolicy"] == "never"
      assert request["sandboxMode"] == "danger-full-access"
      assert request["skipGitRepoCheck"] == true
      assert request["workingDirectory"] == "/workspace"

      assert Enum.map(calls, &hd(&1["argv"])) == ["cp", "cp", "exec"]
      assert config_toml =~ ~s([mcp_servers.orchid])
      assert config_toml =~ ~s(command = "node")
      assert config_toml =~ "mcp_stdio_proxy.mjs"
      assert config_toml =~ ~s([projects."/workspace"])

      assert normalize_codex_home_prefix(Enum.take(argv, 9)) == [
               "exec",
               "-w",
               "/workspace",
               "-e",
               "HOME=/home/agent",
               "-e",
               "CODEX_HOME=/tmp/orchid-codex-home-",
               "-e",
               "ORCHID_CODEX_CLI_PATH=/usr/local/bin/codex"
             ]

      assert Enum.at(argv, 9) == "orchid-project-#{project_id}"
      assert Enum.at(argv, 10) == "sh"
      assert Enum.at(argv, 11) == "-lc"

      assert Enum.at(argv, 12) =~
               ~r/^node '\/opt\/orchid-codex-sdk\/runner\.mjs' '\/tmp\/orchid-codex-request-\d+\.json'; status=\$\?; rm -f '\/tmp\/orchid-codex-request-\d+\.json'; rm -rf '\/tmp\/orchid-codex-home-\d+'; exit \$status$/
    end)
  end

  defp context(message) do
    %{
      system: nil,
      messages: [%{role: :user, content: message}],
      objects: "",
      memory: %{}
    }
  end

  defp with_fake_podman(fun) do
    dir = Path.join(System.tmp_dir!(), "orchid-fake-podman-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    state_dir = Path.join(dir, "state")
    File.mkdir_p!(state_dir)

    script = Path.join(dir, "podman")

    File.write!(script, fake_podman_script())
    File.chmod!(script, 0o755)

    original_path = System.get_env("PATH") || ""
    original_state_dir = System.get_env("FAKE_PODMAN_STATE_DIR")

    System.put_env("PATH", dir <> ":" <> original_path)
    System.put_env("FAKE_PODMAN_STATE_DIR", state_dir)

    try do
      fun.()
    after
      restore_env("PATH", original_path)
      restore_env("FAKE_PODMAN_STATE_DIR", original_state_dir)
      File.rm_rf!(dir)
    end
  end

  defp fake_podman_script do
    """
    #!/usr/bin/env node
    const fs = require("fs");
    const path = require("path");
    const stateDir = process.env.FAKE_PODMAN_STATE_DIR;
    const statePath = path.join(stateDir, "calls.json");
    const requestPath = path.join(stateDir, "request.json");
    const configPath = path.join(stateDir, "config.toml");
    const argv = process.argv.slice(2);

    function loadCalls() {
      if (!fs.existsSync(statePath)) {
        return [];
      }

      return JSON.parse(fs.readFileSync(statePath, "utf8"));
    }

    function saveCalls(calls) {
      fs.writeFileSync(statePath, JSON.stringify(calls));
    }

    if (argv[0] === "cp") {
      const calls = loadCalls();
      calls.push({ argv });
      saveCalls(calls);

      if (fs.existsSync(argv[1])) {
        const stat = fs.statSync(argv[1]);

        if (stat.isFile()) {
          fs.copyFileSync(argv[1], requestPath);
        } else if (stat.isDirectory()) {
          const configToml = path.join(argv[1], "config.toml");

          if (fs.existsSync(configToml)) {
            fs.copyFileSync(configToml, configPath);
          }
        }
      }

      process.exit(0);
    }

    const calls = loadCalls();
    calls.push({ argv });
    saveCalls(calls);

    const payload = JSON.parse(fs.readFileSync(requestPath, "utf8"));
    process.stdout.write(JSON.stringify({
      ok: true,
      content: JSON.stringify({
        argv,
        calls,
        configToml: fs.existsSync(configPath) ? fs.readFileSync(configPath, "utf8") : null,
        request: payload
      })
    }));
    """
  end

  defp normalize_codex_home_prefix(argv) do
    List.update_at(argv, 6, fn
      "CODEX_HOME=" <> _rest -> "CODEX_HOME=/tmp/orchid-codex-home-"
      value -> value
    end)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
