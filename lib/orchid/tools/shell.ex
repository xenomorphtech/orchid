defmodule Orchid.Tools.Shell do
  @moduledoc "Execute shell commands"
  @behaviour Orchid.Tool

  @impl true
  def name, do: "shell"

  @impl true
  def description, do: "Execute a shell command and return the output"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        command: %{
          type: "string",
          description: "The shell command to execute"
        },
        timeout: %{
          type: "integer",
          description: "Timeout in milliseconds (default: 30000)"
        }
      },
      required: ["command"]
    }
  end

  @impl true
  def execute(%{"command" => command} = args, _context) do
    timeout = args["timeout"] || 30_000

    task =
      Task.async(fn ->
        Orchid.OS.Command.run("sh", ["-c", command], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, exit_code}} ->
        {:error, "Exit code #{exit_code}:\n#{output}"}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, "Command timed out after #{timeout}ms"}
    end
  rescue
    e ->
      {:error, "Command failed: #{Exception.message(e)}"}
  end
end
