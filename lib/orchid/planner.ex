defmodule Orchid.Planner do
  @moduledoc """
  Multi-path planning loop (Generator -> Verifier -> Reviser).

  This module explores several structured candidate task arrays concurrently,
  verifies each one, revises rejected plans within the iteration budget, and
  returns the strongest approved plan. If every path exhausts the revision
  budget without approval or the verifier cannot produce a parseable verdict,
  the planner returns the retained candidate as a best-effort, unapproved plan
  so downstream execution can still measure plan quality.
  """

  require Logger

  alias Orchid.Planner.JSON
  alias Orchid.Planner.{Generator, Verifier}
  alias Orchid.Sandbox.Overlay

  @default_opts [
    num_paths: 3,
    max_iterations: 3,
    max_concurrency: 3
  ]

  @verifier_parse_retries 2

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
    max_iterations = bounded_int(opts[:max_iterations], 3, 1, 12)
    max_concurrency = bounded_int(opts[:max_concurrency], num_paths, 1, 8)
    opts = Keyword.put(opts, :max_iterations, max_iterations)

    Logger.info(
      "[GVR] generator: proposing #{num_paths} structured candidate plans, up to #{max_iterations} revision attempts each"
    )

    results =
      1..num_paths
      |> Task.async_stream(
        fn path_index ->
          generate_and_verify(objective, base_sandbox, opts, path_index, num_paths)
        end,
        max_concurrency: max_concurrency,
        timeout: path_timeout(max_iterations),
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.map(&normalize_path_result/1)

    approved =
      Enum.flat_map(results, fn
        {:approved, tasks, reason} -> [{tasks, reason}]
        _ -> []
      end)

    best_effort =
      Enum.flat_map(results, fn
        {:flawed, tasks, critique} when is_list(tasks) and tasks != [] ->
          [{:flawed, tasks, critique}]

        {:unverified, tasks, reason} when is_list(tasks) and tasks != [] ->
          [{:unverified, tasks, reason}]

        _ ->
          []
      end)

    case {approved, best_effort} do
      {[], [{status, tasks, reason} | _rest]} ->
        Logger.info(
          "[GVR] verifier: executing best-effort #{best_effort_label(status)} plan with no approved path: #{truncate(reason, 240)}"
        )

        {:ok, tasks}

      {[], []} ->
        {:error, rejected_summary(results)}

      {[{tasks, reason} | _rest], _} ->
        Logger.info("[GVR] verifier: approved structured plan: #{truncate(reason, 240)}")
        {:ok, tasks}
    end
  end

  defp generate_and_verify(objective, base_sandbox, opts, path_index, path_count) do
    max_iterations = Keyword.fetch!(opts, :max_iterations)

    plan_opts =
      opts
      |> Keyword.put(:path_index, path_index)
      |> Keyword.put(:path_count, path_count)
      |> Keyword.put(:revision_budget, max_iterations)

    completed_tasks = Keyword.get(plan_opts, :completed_tasks, [])

    overlay = Overlay.branch(base_sandbox)

    try do
      verifier_opts = Keyword.put(plan_opts, :overlay, overlay)
      revise_until_approved(objective, completed_tasks, plan_opts, verifier_opts, [], 1)
    after
      Overlay.discard(overlay)
    end
  end

  defp revise_until_approved(
         objective,
         completed_tasks,
         plan_opts,
         verifier_opts,
         feedback,
         attempt
       ) do
    max_iterations = Keyword.fetch!(plan_opts, :max_iterations)
    path_index = Keyword.fetch!(plan_opts, :path_index)
    path_count = Keyword.fetch!(plan_opts, :path_count)

    attempt_opts =
      plan_opts
      |> Keyword.put(:revision_attempt, attempt)
      |> Keyword.put(:revision_feedback, feedback)

    case Generator.generate(objective, completed_tasks, attempt_opts) do
      {:ok, tasks} ->
        verify_revision(
          objective,
          completed_tasks,
          plan_opts,
          verifier_opts,
          feedback,
          attempt,
          tasks
        )

      {:error, reason} ->
        Logger.info(
          "[GVR] generator path #{path_index}/#{path_count} attempt #{attempt}/#{max_iterations}: retryable miss:\n#{truncate(reason, 2_000)}"
        )

        next_feedback = feedback ++ [generator_feedback(attempt, reason)]

        if retryable_generator_error?(reason) and attempt < max_iterations do
          revise_until_approved(
            objective,
            completed_tasks,
            plan_opts,
            verifier_opts,
            next_feedback,
            attempt + 1
          )
        else
          {:error, retry_summary(next_feedback)}
        end
    end
  end

  defp verify_revision(
         objective,
         completed_tasks,
         plan_opts,
         verifier_opts,
         feedback,
         attempt,
         tasks
       ),
       do:
         verify_revision(
           objective,
           completed_tasks,
           plan_opts,
           verifier_opts,
           feedback,
           attempt,
           tasks,
           1
         )

  defp verify_revision(
         objective,
         completed_tasks,
         plan_opts,
         verifier_opts,
         feedback,
         attempt,
         tasks,
         verifier_retry
       ) do
    max_iterations = Keyword.fetch!(plan_opts, :max_iterations)
    path_index = Keyword.fetch!(plan_opts, :path_index)
    path_count = Keyword.fetch!(plan_opts, :path_count)

    case Verifier.verify(objective, tasks, verifier_opts) do
      {:approved, reason} ->
        Logger.info(
          "[GVR] verifier path #{path_index}/#{path_count} attempt #{attempt}/#{max_iterations}: approved:\n#{truncate(reason, 2_000)}"
        )

        {:approved, tasks, reason}

      {:flawed, critique} ->
        Logger.info(
          "[GVR] verifier path #{path_index}/#{path_count} attempt #{attempt}/#{max_iterations}: flawed:\n#{truncate(critique, 2_000)}"
        )

        next_feedback = feedback ++ [verifier_feedback(attempt, tasks, critique)]

        if attempt < max_iterations do
          revise_until_approved(
            objective,
            completed_tasks,
            plan_opts,
            verifier_opts,
            next_feedback,
            attempt + 1
          )
        else
          {:flawed, tasks, retry_summary(next_feedback)}
        end

      {:retry, reason} ->
        Logger.info(
          "[GVR] verifier path #{path_index}/#{path_count} attempt #{attempt}/#{max_iterations} parse retry #{verifier_retry}/#{@verifier_parse_retries}:\n#{truncate(reason, 2_000)}"
        )

        if verifier_retry < @verifier_parse_retries do
          verify_revision(
            objective,
            completed_tasks,
            plan_opts,
            verifier_opts,
            feedback,
            attempt,
            tasks,
            verifier_retry + 1
          )
        else
          next_feedback = feedback ++ [verifier_retry_feedback(attempt, reason)]

          Logger.info(
            "[GVR] verifier path #{path_index}/#{path_count} attempt #{attempt}/#{max_iterations}: parse retries exhausted; retaining unverified candidate for best-effort execution"
          )

          {:unverified, tasks, retry_summary(next_feedback)}
        end
    end
  end

  defp generator_feedback(attempt, reason) do
    %{
      source: :generator,
      attempt: attempt,
      issue: truncate(reason, 1_500)
    }
  end

  defp verifier_feedback(attempt, tasks, critique) do
    %{
      source: :verifier,
      attempt: attempt,
      critique: truncate(critique, 1_500),
      rejected_plan_json: truncate(encode_tasks(tasks), 2_500)
    }
  end

  defp verifier_retry_feedback(attempt, reason) do
    %{
      source: :verifier_retry,
      attempt: attempt,
      issue: truncate(reason, 1_500)
    }
  end

  defp retryable_generator_error?(reason) when is_binary(reason) do
    not String.starts_with?(reason, "Generator LLM failed:")
  end

  defp retryable_generator_error?(_reason), do: false

  defp retry_summary(feedback) do
    details =
      feedback
      |> Enum.map_join("; ", fn
        %{source: :generator, attempt: attempt, issue: issue} ->
          "attempt #{attempt} generator miss: #{truncate(issue, 180)}"

        %{source: :verifier, attempt: attempt, critique: critique} ->
          "attempt #{attempt} verifier flaw: #{truncate(critique, 180)}"

        %{source: :verifier_retry, attempt: attempt, issue: issue} ->
          "attempt #{attempt} verifier parse miss: #{truncate(issue, 180)}"

        other ->
          truncate(inspect(other), 180)
      end)

    if details == "" do
      "No approved plan after revision budget."
    else
      "No approved plan after revision budget: #{details}"
    end
  end

  defp normalize_path_result({:ok, {:approved, tasks, reason}}), do: {:approved, tasks, reason}
  defp normalize_path_result({:ok, {:flawed, tasks, critique}}), do: {:flawed, tasks, critique}

  defp normalize_path_result({:ok, {:unverified, tasks, reason}}),
    do: {:unverified, tasks, reason}

  defp normalize_path_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_path_result({:exit, reason}), do: {:error, inspect(reason)}
  defp normalize_path_result(other), do: {:error, inspect(other)}

  defp best_effort_label(:flawed), do: "flawed/unapproved"
  defp best_effort_label(:unverified), do: "unverified/unapproved"

  defp rejected_summary(results) do
    details =
      results
      |> Enum.with_index(1)
      |> Enum.map_join("; ", fn
        {{:flawed, _tasks, critique}, index} ->
          "path #{index} flawed (best-effort candidate retained): #{truncate(critique, 180)}"

        {{:unverified, _tasks, reason}, index} ->
          "path #{index} unverified (best-effort candidate retained): #{truncate(reason, 180)}"

        {{:error, reason}, index} ->
          "path #{index} error: #{truncate(reason, 180)}"

        {other, index} ->
          "path #{index}: #{truncate(inspect(other), 180)}"
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

  defp path_timeout(max_iterations) do
    max_iterations
    |> max(3)
    |> min(8)
    |> Kernel.*(4)
    |> :timer.minutes()
  end

  defp truncate(term, max) do
    text = JSON.render_error(term)

    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end
end
