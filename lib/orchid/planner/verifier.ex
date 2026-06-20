defmodule Orchid.Planner.Verifier do
  @moduledoc """
  LLM-backed Verifier node for recursive G-V-R planning.

  The verifier critiques a structured task array with balanced prompting: it must
  argue the flawless case and the terrible case before returning an approval or
  a concrete flaw critique.
  """

  alias Orchid.{LLM, Project}
  alias Orchid.Planner.{Generator, JSON, LLMMemo}

  require Logger

  @default_output_retry_attempts 6

  @default_llm_config %{
    provider: :openrouter,
    model: :nex_n2_pro,
    disable_tools: true,
    max_turns: 1,
    max_tokens: 2_200
  }

  @type decision :: {:approved, String.t()} | {:flawed, String.t()} | {:retry, String.t()}

  @spec critique(String.t(), [Generator.task()], keyword() | map()) :: decision()
  def critique(objective, tasks, opts \\ []) do
    verify(objective, tasks, opts)
  end

  @spec verify(String.t(), [Generator.task()], keyword() | map()) :: decision()
  def verify(objective, tasks, opts \\ [])

  def verify(objective, tasks, opts) when is_binary(objective) and is_list(tasks) do
    opts = normalize_opts(opts)
    plan_json = encode_tasks(tasks)
    prompt = user_prompt(objective, plan_json, workspace_context(opts), opts)

    system = system_prompt()

    LLMMemo.fetch(
      llm_cache_key(:verifier, system, prompt, opts),
      opts,
      &cacheable_verify_result?/1,
      fn ->
        case llm_text_with_output_retry(system, prompt, opts, 1, output_retry_attempts(opts)) do
          {:ok, raw} -> parse_decision(raw)
          {:error, reason} -> {:flawed, reason}
        end
      end
    )
  end

  def verify(_objective, _tasks, _opts),
    do: {:flawed, "objective must be a string and tasks must be a list"}

  @spec parse_decision(String.t()) :: decision()
  def parse_decision(raw) when is_binary(raw) do
    case JSON.extract_json(raw, :object) do
      {:ok, decoded} ->
        case decision_status(decoded) do
          {:ok, :approved} -> {:approved, decision_message(decoded, "reason", raw)}
          {:ok, :flawed} -> {:flawed, decision_message(decoded, "critique", raw)}
          {:error, reason} -> {:retry, raw_critique(raw, reason)}
        end

      {:error, reason} ->
        {:retry, raw_critique(raw, reason)}
    end
  end

  def parse_decision(_raw), do: {:retry, "Verifier output must be a string"}

  defp raw_critique(raw, reason) do
    """
    Verifier returned a non-JSON or invalid decision: #{reason}

    Raw verifier output:
    #{String.slice(raw, 0, 1_500)}
    """
    |> String.trim()
  end

  defp system_prompt do
    """
    You are the Verifier node in a recursive Generator-Verifier-Reviser planner.

    You review a proposed JSON task array for a real autonomous agent. You are
    not allowed to rubber-stamp the plan. You must reason in two opposed passes:

    1. Argue why the plan is flawless and will succeed.
    2. Argue why the plan is terrible, focusing on missing prerequisites,
       invalid tool usage, guessed paths, unsafe sequencing, or over-broad tool
       tasks that should have been delegate tasks.
    3. Weigh both arguments and decide.

    Return ONLY valid JSON. Do not include markdown.
    """
    |> String.trim()
  end

  defp user_prompt(objective, plan_json, workspace_context, opts) do
    execution_budget_note = execution_budget_note(opts)

    """
    OBJECTIVE:
    #{objective}

    PROPOSED TASK ARRAY:
    #{plan_json}

    WORKSPACE CONTEXT:
    #{workspace_context}

    #{execution_budget_note}

    Return exactly one JSON object:
    {
      "status": "approved" | "flawed",
      "flawless_case": "best argument that the task array will succeed",
      "terrible_case": "best argument that the task array will fail",
      "reason": "approval reason when status is approved",
      "critique": "specific fixable critique when status is flawed"
    }
    """
    |> String.trim()
  end

  defp execution_budget_note(opts) do
    remaining = Map.get(opts, :execution_step_budget_remaining)
    total = Map.get(opts, :execution_step_budget_total)

    if is_integer(remaining) do
      total_text = if is_integer(total), do: " of #{total}", else: ""

      """
      EXECUTION STEP BUDGET:
      Planner generation, verification, and revision are outside the executor
      step budget. The executor has #{remaining}#{total_text} successful tool
      step(s) remaining. Delegate tasks recursively plan and execute their own
      tools, so treat delegate-heavy plans as expensive under tight budgets. If
      the objective, workspace context, or completed history already names files
      and commands, require concrete read/list/grep/shell/edit/tool tasks rather
      than delegation. A plan that stops at a partial subsystem while the
      acceptance check still requires downstream work is flawed unless it
      explicitly schedules the downstream work or a follow-up verification path.
      A plan is also flawed when an edit or shell write relies on file contents,
      constants, APIs, or expected outputs that are only read by earlier tasks in
      the same array and are not already present in the objective or completed
      history; require an inspection-only round followed by replanning instead.
      """
      |> String.trim()
    else
      ""
    end
  end

  defp llm_text_with_output_retry(system, user, opts, attempt, max_attempts) do
    case llm_text(system, user, opts) do
      {:ok, raw} ->
        {:ok, raw}

      {:error, reason = "Verifier returned empty output"} when attempt < max_attempts ->
        log_output_retry(attempt, max_attempts, reason)
        llm_text_with_output_retry(system, user, opts, attempt + 1, max_attempts)

      {:error, reason = "Verifier returned empty output"} ->
        log_output_retry(attempt, max_attempts, reason)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp log_output_retry(attempt, max_attempts, reason) do
    Logger.info("[GVR] verifier output retry #{attempt}/#{max_attempts}: #{reason}")
  end

  defp llm_cache_key(node, system, user, opts) do
    [
      node: node,
      llm_module: llm_module(opts),
      llm_config: llm_config(opts),
      system: system,
      user: user
    ]
  end

  defp cacheable_verify_result?({:approved, reason}) when is_binary(reason), do: true

  defp cacheable_verify_result?({:flawed, critique}) when is_binary(critique) do
    not String.starts_with?(critique, "Verifier returned empty output") and
      not String.starts_with?(critique, "Verifier LLM failed:")
  end

  defp cacheable_verify_result?(_result), do: false

  defp llm_text(system, user, opts) do
    context = %{
      system: system,
      messages: [%{role: :user, content: user}],
      objects: "",
      memory: %{}
    }

    case llm_module(opts).chat(llm_config(opts), context) do
      {:ok, %{content: content}} when is_binary(content) ->
        trimmed = String.trim(content)

        if trimmed == "" do
          {:error, "Verifier returned empty output"}
        else
          {:ok, trimmed}
        end

      {:error, reason} ->
        {:error, "Verifier LLM failed: #{JSON.render_error(reason)}"}
    end
  end

  defp llm_module(opts) do
    Map.get(opts, :llm_module, LLM)
  end

  defp llm_config(opts) do
    llm_config =
      opts
      |> Map.get(:llm_config, %{})
      |> normalize_opts()

    @default_llm_config
    |> Map.merge(drop_nil_values(llm_config))
    |> Map.put(:disable_tools, true)
  end

  defp workspace_context(opts) do
    cond do
      is_binary(Map.get(opts, :workspace_context)) ->
        Map.fetch!(opts, :workspace_context)

      is_binary(Map.get(opts, :project_id)) ->
        project_workspace_context(Map.fetch!(opts, :project_id))

      Map.has_key?(opts, :overlay) ->
        "Verifier overlay: #{inspect(Map.get(opts, :overlay), limit: 20)}"

      true ->
        "(not provided)"
    end
  end

  defp project_workspace_context(project_id) do
    root = Project.files_path(project_id)

    files =
      if File.dir?(root) do
        root
        |> Path.join("**/*")
        |> Path.wildcard(match_dot: true)
        |> Enum.filter(&File.regular?/1)
        |> Enum.take(80)
        |> Enum.map(&Path.relative_to(&1, root))
      else
        []
      end

    if files == [] do
      "(workspace appears empty)"
    else
      Enum.join(files, "\n")
    end
  end

  defp decision_status(%{"status" => status}) when is_binary(status) do
    case status |> String.trim() |> String.downcase() do
      "approved" -> {:ok, :approved}
      "approve" -> {:ok, :approved}
      "flawed" -> {:ok, :flawed}
      "rejected" -> {:ok, :flawed}
      _ -> {:error, "status must be approved or flawed"}
    end
  end

  defp decision_status(_decoded), do: {:error, "missing status"}

  defp decision_message(decoded, preferred_key, raw) do
    [
      Map.get(decoded, preferred_key),
      Map.get(decoded, "feedback"),
      Map.get(decoded, "reason"),
      Map.get(decoded, "critique"),
      balanced_cases(decoded)
    ]
    |> Enum.find_value(fn
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> nil
    end)
    |> case do
      nil -> String.slice(raw, 0, 800)
      message -> message
    end
  end

  defp balanced_cases(decoded) do
    flawless = Map.get(decoded, "flawless_case")
    terrible = Map.get(decoded, "terrible_case")

    case {flawless, terrible} do
      {a, b} when is_binary(a) and is_binary(b) ->
        "Flawless case: #{a}\nTerrible case: #{b}"

      _ ->
        nil
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

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(_opts), do: %{}

  defp output_retry_attempts(opts) do
    opts
    |> Map.get(:verifier_output_retry_attempts, @default_output_retry_attempts)
    |> bounded_int(@default_output_retry_attempts, 1, 8)
  end

  defp bounded_int(value, _default, min, max) when is_integer(value) do
    value |> max(min) |> min(max)
  end

  defp bounded_int(_value, default, _min, _max), do: default

  defp drop_nil_values(map) do
    Map.new(map, fn {key, value} -> {key, value} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
