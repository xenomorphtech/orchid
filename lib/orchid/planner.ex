defmodule Orchid.Planner do
  @moduledoc """
  Multi-path planning loop (Generator -> Verifier).

  This module explores several structured candidate task arrays concurrently,
  verifies each one, and returns the strongest approved plan.
  """

  require Logger

  alias Orchid.Planner.{Generator, Verifier}
  alias Orchid.Sandbox.Overlay

  @default_opts [
    num_paths: 3,
    max_iterations: 3,
    max_concurrency: 3
  ]

  @type task :: Generator.task()

  @spec plan(String.t(), any(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def plan(objective, base_sandbox, opts \\ []) when is_binary(objective) do
    case plan_tasks(objective, base_sandbox, opts) do
      {:ok, tasks} -> {:ok, encode_tasks(tasks)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec plan_tasks(String.t(), any(), keyword()) :: {:ok, [task()]} | {:error, String.t()}
  def plan_tasks(objective, base_sandbox, opts \\ []) when is_binary(objective) do
    opts = Keyword.merge(@default_opts, opts)
    num_paths = bounded_int(opts[:num_paths], 3, 1, 8)
    _max_iterations = bounded_int(opts[:max_iterations], 3, 0, 6)
    max_concurrency = bounded_int(opts[:max_concurrency], num_paths, 1, 8)

    Logger.info("[GVR] generator: proposing #{num_paths} structured candidate plans")

    results =
      1..num_paths
      |> Task.async_stream(
        fn path_index ->
          generate_and_verify(objective, base_sandbox, opts, path_index, num_paths)
        end,
        max_concurrency: max_concurrency,
        timeout: :timer.minutes(10),
        ordered: true
      )
      |> Enum.map(&normalize_path_result/1)

    approved =
      Enum.flat_map(results, fn
        {:approved, tasks, reason} -> [{tasks, reason}]
        _ -> []
      end)

    case approved do
      [] ->
        {:error, rejected_summary(results)}

      [{tasks, reason} | _rest] ->
        Logger.info("[GVR] verifier: approved structured plan: #{truncate(reason, 240)}")
        {:ok, tasks}
    end
  end

  defp generate_and_verify(objective, base_sandbox, opts, path_index, path_count) do
    plan_opts =
      opts
      |> Keyword.put(:path_index, path_index)
      |> Keyword.put(:path_count, path_count)

    overlay = Overlay.branch(base_sandbox)

    try do
      verifier_opts = Keyword.put(plan_opts, :overlay, overlay)

      with {:ok, tasks} <- Generator.generate(objective, [], plan_opts) do
        case Verifier.verify(objective, tasks, verifier_opts) do
          {:approved, reason} -> {:approved, tasks, reason}
          {:flawed, critique} -> {:flawed, tasks, critique}
        end
      end
    after
      Overlay.discard(overlay)
    end
  end

  defp normalize_path_result({:ok, {:approved, tasks, reason}}), do: {:approved, tasks, reason}
  defp normalize_path_result({:ok, {:flawed, _tasks, critique}}), do: {:flawed, critique}
  defp normalize_path_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_path_result({:exit, reason}), do: {:error, inspect(reason)}
  defp normalize_path_result(other), do: {:error, inspect(other)}

  defp rejected_summary(results) do
    details =
      results
      |> Enum.with_index(1)
      |> Enum.map_join("; ", fn
        {{:flawed, critique}, index} -> "path #{index} flawed: #{truncate(critique, 180)}"
        {{:error, reason}, index} -> "path #{index} error: #{truncate(reason, 180)}"
        {other, index} -> "path #{index}: #{truncate(inspect(other), 180)}"
      end)

    if details == "" do
      "All generated plans failed verification."
    else
      "All generated plans failed verification: #{details}"
    end
  end

  defp encode_tasks(tasks) do
    tasks
    |> Enum.map(&task_to_json_map/1)
    |> Jason.encode!(pretty: true)
  end

  defp task_to_json_map(task) do
    base = %{
      id: Map.fetch!(task, :id),
      type: task |> Map.fetch!(:type) |> Atom.to_string(),
      objective: Map.fetch!(task, :objective)
    }

    if task[:type] == :tool do
      base
      |> Map.put(:tool, Map.get(task, :tool))
      |> Map.put(:args, Map.get(task, :args, %{}))
    else
      base
    end
  end

  defp bounded_int(value, _default, min, max) when is_integer(value) do
    value |> max(min) |> min(max)
  end

  defp bounded_int(_value, default, _min, _max), do: default

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end

  defp truncate(text, _max), do: to_string(text)
end
