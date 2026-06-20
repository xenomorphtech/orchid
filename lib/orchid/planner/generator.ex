defmodule Orchid.Planner.Generator do
  @moduledoc """
  LLM-backed Generator node for recursive G-V-R planning.

  The generator decomposes one objective into a JSON task array. Each task is
  either a `:delegate` node for unresolved work or a concrete `:tool` node with
  exact Orchid tool arguments.
  """

  alias Orchid.LLM
  alias Orchid.Planner.{JSON, LLMMemo}

  require Logger

  @default_allowed_tools ~w(shell read edit list grep task_report_result)
  @default_output_retry_attempts 6

  @default_llm_config %{
    provider: :openrouter,
    model: :nex_n2_pro,
    disable_tools: true,
    max_turns: 1,
    max_tokens: 2_400
  }

  @type task_type :: :delegate | :tool

  @type task :: %{
          required(:id) => String.t(),
          required(:type) => task_type(),
          required(:objective) => String.t(),
          optional(:tool) => String.t(),
          optional(:args) => map()
        }

  @spec decompose(String.t(), [task()], keyword() | map()) ::
          {:ok, [task()]} | {:error, String.t()}
  def decompose(objective, completed_tasks \\ [], opts \\ []) do
    generate(objective, completed_tasks, opts)
  end

  @spec generate(String.t(), [task()], keyword() | map()) ::
          {:ok, [task()]} | {:error, String.t()}
  def generate(objective, completed_tasks \\ [], opts \\ [])

  def generate(objective, completed_tasks, opts)
      when is_binary(objective) and is_list(completed_tasks) do
    opts = normalize_opts(opts)
    system = system_prompt()
    user = user_prompt(objective, completed_tasks, opts)

    LLMMemo.fetch(
      llm_cache_key(:generator, system, user, opts),
      opts,
      &cacheable_generate_result?/1,
      fn -> generate_with_output_retry(system, user, opts, 1, output_retry_attempts(opts)) end
    )
  end

  def generate(_objective, _completed_tasks, _opts),
    do: {:error, "objective must be a string and completed_tasks must be a list"}

  @spec parse_task_array(String.t()) :: {:ok, [task()]} | {:error, String.t()}
  def parse_task_array(raw) when is_binary(raw) do
    with {:ok, list} <- JSON.extract_json(raw, :array),
         {:ok, tasks} <- normalize_tasks(list) do
      {:ok, tasks}
    end
  end

  def parse_task_array(_raw), do: {:error, "generator output must be a string"}

  defp system_prompt do
    """
    You are the Generator node in a recursive Generator-Verifier-Reviser planner.

    Decompose the current objective into immediate next tasks using lazy
    hierarchical planning:

    - Use type "delegate" only when the sub-task is broad enough to need its
      own planning loop.
    - Use type "tool" only when the exact Orchid tool name and exact JSON args
      are known now.

    Strict rules for tool tasks:
    - Do not emit placeholders, TODOs, comments-as-commands, or guessed paths.
    - If a shell command is needed, args.command must be concrete and runnable.
    - If a file path, pattern, command flag, or file content is unknown but can
      be discovered with read, list, grep, or shell, emit that concrete
      inspection tool task. The runner replans after tool tasks complete.
    - If an edit or shell write depends on information that would be discovered
      by an earlier task in the same array, stop at the inspection tasks for
      this round. Do not guess constants, APIs, or expected outputs; wait for
      the next planning round to use completed history.
    - Do not emit a delegate merely to defer file inspection, code editing, test
      execution, or result reporting that the available tools can perform.

    Return ONLY a valid JSON array of task objects. Do not include markdown.
    """
    |> String.trim()
  end

  defp user_prompt(objective, completed_tasks, opts) do
    allowed_tools = allowed_tools(opts) |> Enum.join(", ")
    path_note = path_note(opts)
    revision_note = revision_note(opts)
    execution_budget_note = execution_budget_note(opts)

    """
    CURRENT OBJECTIVE:
    #{objective}

    COMPLETED HISTORY:
    #{inspect(completed_tasks, limit: 50)}

    #{path_note}

    #{revision_note}

    #{execution_budget_note}

    AVAILABLE ORCHID TOOLS FOR TOOL TASKS:
    #{allowed_tools}

    WORKSPACE CONTEXT:
    #{Map.get(opts, :workspace_context, "(not provided)")}

    Output a JSON array. Every object must include:
    - "id": a stable, short, unique identifier string
    - "type": exactly "delegate" or "tool"
    - "objective": one concise sentence

    Tool objects must also include:
    - "tool": exact Orchid tool name from the allowed list
    - "args": exact JSON object for that tool
    """
    |> String.trim()
  end

  defp revision_note(opts) do
    feedback = Map.get(opts, :revision_feedback, [])

    if is_list(feedback) and feedback != [] do
      attempt = Map.get(opts, :revision_attempt)
      budget = Map.get(opts, :revision_budget)
      attempt_line = revision_attempt_line(attempt, budget)

      """
      REVISION FEEDBACK:
      #{attempt_line}
      The previous candidate plan was not accepted. Treat verifier critiques as
      mandatory rewrite instructions, not advice. Produce a revised JSON array
      that directly fixes every issue below. When a critique asks to split,
      sequence, add evidence, or make a dependency explicit, change the task
      array accordingly with separate ordered tasks or concrete task objectives.
      Do not repeat rejected structure, invalid task types, prose-only answers,
      or markdown.

      #{Enum.map_join(feedback, "\n\n", &format_revision_feedback/1)}
      """
      |> String.trim()
    else
      ""
    end
  end

  defp revision_attempt_line(attempt, budget)
       when is_integer(attempt) and is_integer(budget) do
    "Revision attempt #{attempt} of #{budget}."
  end

  defp revision_attempt_line(_attempt, _budget), do: "Revision attempt."

  defp format_revision_feedback(%{source: :generator, attempt: attempt, issue: issue}) do
    """
    Attempt #{attempt} generator parse/validation miss:
    #{limit_text(issue, 1_500)}
    """
    |> String.trim()
  end

  defp format_revision_feedback(%{
         source: :verifier,
         attempt: attempt,
         critique: critique,
         rejected_plan_json: rejected_plan_json
       }) do
    """
    Attempt #{attempt} verifier critique (mandatory revision instructions):
    #{limit_text(critique, 1_500)}

    Rejected task array:
    #{limit_text(rejected_plan_json, 2_500)}
    """
    |> String.trim()
  end

  defp format_revision_feedback(other), do: inspect(other, limit: 20)

  defp path_note(opts) do
    index = Map.get(opts, :path_index)
    count = Map.get(opts, :path_count)

    cond do
      is_integer(index) and is_integer(count) and count > 1 ->
        """
        CANDIDATE PLAN #{index} OF #{count}:
        Make this decomposition meaningfully different where the objective
        allows alternatives, but never sacrifice executability.
        """
        |> String.trim()

      true ->
        ""
    end
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
      tools, so they are expensive under tight budgets. Prefer a short,
      topologically ordered list of concrete tool tasks whenever the objective,
      workspace context, or completed history already names the files and
      commands. Do not delegate just to restate known work; include the final
      acceptance or verification command as a concrete tool task when it is
      known.
      """
      |> String.trim()
    else
      ""
    end
  end

  defp generate_with_output_retry(system, user, opts, attempt, max_attempts) do
    case generate_once(system, user, opts) do
      {:ok, tasks} ->
        {:ok, tasks}

      {:retry, reason} when attempt < max_attempts ->
        log_output_retry(attempt, max_attempts, reason)
        generate_with_output_retry(system, user, opts, attempt + 1, max_attempts)

      {:retry, reason} ->
        log_output_retry(attempt, max_attempts, reason)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_once(system, user, opts) do
    with {:ok, raw} <- llm_text(system, user, opts) do
      case parse_task_array(raw) do
        {:ok, tasks} -> {:ok, tasks}
        {:error, reason} -> retryable_output_miss(reason)
      end
    else
      {:error, reason = "Generator returned empty output"} -> {:retry, reason}
      {:error, reason} -> {:error, reason}
    end
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

  defp cacheable_generate_result?({:ok, tasks}) when is_list(tasks), do: true
  defp cacheable_generate_result?(_result), do: false

  defp retryable_output_miss("no decodable JSON array found" = reason), do: {:retry, reason}

  defp retryable_output_miss(reason), do: {:error, reason}

  defp log_output_retry(attempt, max_attempts, reason) do
    Logger.info(
      "[GVR] generator output retry #{attempt}/#{max_attempts}: #{limit_text(reason, 2_000)}"
    )
  end

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
          {:error, "Generator returned empty output"}
        else
          {:ok, trimmed}
        end

      {:error, reason} ->
        {:error, "Generator LLM failed: #{inspect(reason)}"}
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

  defp allowed_tools(opts) do
    case Map.get(opts, :allowed_tools) do
      names when is_list(names) and names != [] -> Enum.map(names, &to_string/1)
      _ -> @default_allowed_tools
    end
  end

  defp normalize_tasks([]), do: {:ok, []}

  defp normalize_tasks(tasks) do
    tasks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {raw_task, index}, {:ok, acc} ->
      case normalize_task(raw_task, index) do
        {:ok, task} -> {:cont, {:ok, acc ++ [task]}}
        {:error, reason} -> {:halt, {:error, "task #{index}: #{reason}"}}
      end
    end)
  end

  defp normalize_task(raw_task, index) when is_map(raw_task) do
    type = raw_task |> string_field("type") |> normalize_type()
    objective = raw_task |> string_field("objective") |> blank_to_nil()
    id = raw_task |> string_field("id") |> blank_to_nil() || "task_#{index}"

    cond do
      type not in [:delegate, :tool] ->
        {:error, "type must be delegate or tool"}

      is_nil(objective) ->
        {:error, "objective is required"}

      type == :delegate ->
        {:ok, %{id: id, type: :delegate, objective: objective}}

      true ->
        normalize_tool_task(raw_task, id, objective)
    end
  end

  defp normalize_task(_raw_task, _index), do: {:error, "task must be a JSON object"}

  defp normalize_tool_task(raw_task, id, objective) do
    tool = raw_task |> string_field("tool") |> blank_to_nil()
    args = map_field(raw_task, "args")

    cond do
      is_nil(tool) ->
        {:error, "tool task requires tool"}

      not is_map(args) ->
        {:error, "tool task requires args object"}

      true ->
        {:ok, %{id: id, type: :tool, objective: objective, tool: tool, args: args}}
    end
  end

  defp string_field(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> value |> Atom.to_string() |> String.trim()
      _ -> nil
    end
  end

  defp map_field(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp normalize_type(nil), do: nil

  defp normalize_type(value) when is_binary(value) do
    case String.downcase(value) do
      "delegate" -> :delegate
      "tool" -> :tool
      _ -> nil
    end
  end

  defp normalize_type(_value), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp output_retry_attempts(opts) do
    opts
    |> Map.get(:generator_output_retry_attempts, @default_output_retry_attempts)
    |> bounded_int(@default_output_retry_attempts, 1, 8)
  end

  defp bounded_int(value, _default, min, max) when is_integer(value) do
    value |> max(min) |> min(max)
  end

  defp bounded_int(_value, default, _min, _max), do: default

  defp limit_text(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end

  defp limit_text(term, max), do: term |> inspect(limit: 20) |> limit_text(max)

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(_opts), do: %{}

  defp drop_nil_values(map) do
    Map.new(map, fn {key, value} -> {key, value} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
