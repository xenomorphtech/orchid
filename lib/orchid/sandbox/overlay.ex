defmodule Orchid.Sandbox.Overlay do
  @moduledoc """
  Application-level union FS fallback.
  Used when real overlay mount is unavailable inside the container.
  Upper layer wins for reads, writes always go to upper.
  """

  @doc """
  Create a lightweight temporary overlay context for verification/dry-run logic.
  """
  def branch(base_sandbox) do
    id = :erlang.unique_integer([:positive, :monotonic])
    tmp_dir = Path.join(System.tmp_dir!(), "orchid-overlay-#{id}")
    File.mkdir_p!(tmp_dir)

    %{
      id: id,
      base: base_sandbox,
      tmp_dir: tmp_dir,
      created_at: DateTime.utc_now()
    }
  end

  @doc """
  Discard a temporary overlay context created by `branch/1`.
  """
  def discard(%{tmp_dir: tmp_dir}) when is_binary(tmp_dir) do
    _ = File.rm_rf(tmp_dir)
    :ok
  end

  def discard(_), do: :ok

  @doc """
  Read a file, checking upper dir first then lower.
  """
  def union_read(rel_path, upper, lower) do
    upper_file = Path.join(upper, rel_path)
    lower_file = Path.join(lower, rel_path)

    cond do
      File.exists?(upper_file) -> File.read(upper_file)
      File.exists?(lower_file) -> File.read(lower_file)
      true -> {:error, :enoent}
    end
  end

  @doc """
  Write a file to the upper layer, creating parent dirs as needed.
  """
  def union_write(rel_path, content, upper) do
    target = Path.join(upper, rel_path)
    File.mkdir_p!(Path.dirname(target))
    File.write(target, content)
  end

  @doc """
  List directory contents, merging upper and lower. Upper entries win on conflict.
  """
  def union_list(rel_path, upper, lower) do
    upper_dir = Path.join(upper, rel_path)
    lower_dir = Path.join(lower, rel_path)

    upper_entries =
      case File.ls(upper_dir) do
        {:ok, entries} -> MapSet.new(entries)
        _ -> MapSet.new()
      end

    lower_entries =
      case File.ls(lower_dir) do
        {:ok, entries} -> MapSet.new(entries)
        _ -> MapSet.new()
      end

    merged = MapSet.union(upper_entries, lower_entries) |> MapSet.to_list() |> Enum.sort()

    entries =
      Enum.map(merged, fn entry ->
        # Check upper first for type info
        full_path =
          if MapSet.member?(upper_entries, entry) do
            Path.join(upper_dir, entry)
          else
            Path.join(lower_dir, entry)
          end

        type = if File.dir?(full_path), do: "dir", else: "file"
        "#{type}\t#{entry}"
      end)

    {:ok, Enum.join(entries, "\n")}
  end

  @doc """
  Grep across both upper and lower layers, deduplicating by relative path.
  Upper layer results take priority.
  """
  def union_grep(pattern, rel_path, upper, lower, opts \\ []) do
    upper_dir = Path.join(upper, rel_path)
    lower_dir = Path.join(lower, rel_path)
    glob = opts[:glob]

    upper_results = run_grep(pattern, upper_dir, glob)
    lower_results = run_grep(pattern, lower_dir, glob)

    # Get files that have results in upper, so we skip those from lower
    upper_files =
      upper_results
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> line |> String.split(":", parts: 2) |> List.first() end)
      |> MapSet.new()

    # Filter lower results to exclude files that exist in upper
    filtered_lower =
      lower_results
      |> String.split("\n", trim: true)
      |> Enum.reject(fn line ->
        file = line |> String.split(":", parts: 2) |> List.first()
        # Translate lower path to relative and check if upper has it
        rel = String.replace_prefix(file, lower_dir <> "/", "")
        upper_rel = Path.join(upper_dir, rel)
        MapSet.member?(upper_files, upper_rel)
      end)
      |> Enum.join("\n")

    combined =
      [upper_results, filtered_lower]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    if combined == "", do: {:ok, "No matches found"}, else: {:ok, combined}
  end

  defp run_grep(pattern, dir, glob) do
    if File.dir?(dir) do
      args = ["-n", "--no-heading", pattern, dir]
      args = if glob, do: args ++ ["--glob", glob], else: args

      case Orchid.OS.Command.run("rg", args, stderr_to_stdout: true) do
        {output, 0} -> String.trim(output)
        _ -> ""
      end
    else
      ""
    end
  end
end
