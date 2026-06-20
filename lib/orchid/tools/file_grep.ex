defmodule Orchid.Tools.FileGrep do
  @moduledoc "Search for patterns in files"
  @behaviour Orchid.Tool

  @impl true
  def name, do: "grep"

  @impl true
  def description, do: "Search for a pattern in files using ripgrep"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        pattern: %{
          type: "string",
          description: "The regex pattern to search for"
        },
        path: %{
          type: "string",
          description: "File or directory to search in (default: current directory)"
        },
        glob: %{
          type: "string",
          description: "Glob pattern to filter files (e.g. \"*.ex\")"
        }
      },
      required: ["pattern"]
    }
  end

  @impl true
  def execute(%{"pattern" => pattern} = args, _context) do
    path = args["path"] || "."

    cmd_args = ["-n", "--no-heading", pattern, path]
    cmd_args = if glob = args["glob"], do: cmd_args ++ ["--glob", glob], else: cmd_args

    case Orchid.OS.Command.run("rg", cmd_args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, 1} -> {:ok, "No matches found"}
      {output, _} -> {:error, "grep failed: #{output}"}
    end
  rescue
    e -> {:error, "grep failed: #{Exception.message(e)}"}
  end

  def execute(_args, _context) do
    {:error, "pattern is required"}
  end
end
