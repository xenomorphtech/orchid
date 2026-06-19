defmodule Orchid.Autonomy.Scorer do
  @moduledoc """
  Deterministic scorer for autonomy benchmark runs.

  The scorer never calls an LLM. Closure is decided from the runner's captured
  deterministic `success_check` result, or by explicitly pure predicates
  supplied by a benchmark.
  """

  alias Orchid.Autonomy.{Benchmark, Runner}
  alias Orchid.Sandbox

  @type score :: %{
          required(:unattended_depth) => non_neg_integer(),
          required(:goal_closure) => boolean(),
          required(:recovery_rate) => float()
        }

  @type option :: {:success_timeout_ms, pos_integer()}

  @doc """
  Score a run result with deterministic checks only.
  """
  @spec score(Runner.run_result(), [option()]) :: score()
  def score(%{benchmark: %Benchmark{} = benchmark} = run_result, opts \\ [])
      when is_list(opts) do
    %{
      unattended_depth: Map.get(run_result, :depth, 0),
      goal_closure: goal_closure(run_result, benchmark, opts),
      recovery_rate: recovery_rate(Map.get(run_result, :recovered, []))
    }
  end

  defp goal_closure(%{closed: closed}, _benchmark, _opts) when is_boolean(closed), do: closed

  defp goal_closure(run_result, benchmark, opts) do
    success_check_passed?(benchmark.success_check, run_result, opts)
  end

  @doc """
  Execute a benchmark success check without using an LLM.
  """
  @spec success_check_passed?(Benchmark.success_check(), Runner.run_result() | map(), [option()]) ::
          boolean()
  def success_check_passed?(success_check, run_result, opts \\ [])

  def success_check_passed?({:shell, command}, %{project_id: project_id}, opts)
      when is_binary(project_id) and is_binary(command) do
    timeout = Keyword.get(opts, :success_timeout_ms, 120_000)

    case Sandbox.exec(project_id, command, timeout: timeout) do
      {:ok, _output} -> true
      {:error, _reason} -> false
    end
  end

  def success_check_passed?({:file_exists, path}, run_result, opts) when is_binary(path) do
    success_check_passed?({:shell, "test -f #{shell_escape(path)}"}, run_result, opts)
  end

  def success_check_passed?(
        {:file_contains, path, %Regex{} = pattern},
        %{project_id: project_id},
        _opts
      )
      when is_binary(project_id) and is_binary(path) do
    case Sandbox.read_file(project_id, path) do
      {:ok, content} -> Regex.match?(pattern, content)
      {:error, _reason} -> false
    end
  end

  def success_check_passed?(
        {:file_contains, path, needle},
        %{project_id: project_id},
        _opts
      )
      when is_binary(project_id) and is_binary(path) and is_binary(needle) do
    case Sandbox.read_file(project_id, path) do
      {:ok, content} -> String.contains?(content, needle)
      {:error, _reason} -> false
    end
  end

  def success_check_passed?({:predicate, predicate}, run_result, _opts)
      when is_function(predicate, 1) do
    try do
      predicate.(run_result) == true
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  def success_check_passed?(_success_check, _run_result, _opts), do: false

  defp recovery_rate(events) when is_list(events) do
    injected_events = Enum.filter(events, &injected?/1)

    case injected_events do
      [] ->
        0.0

      _ ->
        recovered = Enum.count(injected_events, &recovered?/1)
        recovered / length(injected_events)
    end
  end

  defp injected?(%{injected: false}), do: false
  defp injected?(_event), do: true

  defp recovered?(%{recovered: true}), do: true
  defp recovered?(%{status: :recovered}), do: true
  defp recovered?(true), do: true
  defp recovered?(_event), do: false

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
