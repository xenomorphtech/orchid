defmodule Orchid.Planner.Verifier do
  @moduledoc """
  LLM-backed Verifier node for recursive G-V-R planning.

  The verifier critiques a structured task array with balanced prompting: it must
  argue the flawless case and the terrible case before returning an approval or
  a concrete flaw critique.
  """

  alias Orchid.{LLM, Project}
  alias Orchid.Planner.Generator

  @default_llm_config %{
    provider: :openrouter,
    model: :nex_n2_pro,
    disable_tools: true,
    max_turns: 1,
    max_tokens: 2_200
  }

  @type decision :: {:approved, String.t()} | {:flawed, String.t()}

  @spec critique(String.t(), [Generator.task()], keyword() | map()) :: decision()
  def critique(objective, tasks, opts \\ []) do
    verify(objective, tasks, opts)
  end

  @spec verify(String.t(), [Generator.task()], keyword() | map()) :: decision()
  def verify(objective, tasks, opts \\ [])

  def verify(objective, tasks, opts) when is_binary(objective) and is_list(tasks) do
    opts = normalize_opts(opts)
    plan_json = encode_tasks(tasks)

    prompt = user_prompt(objective, plan_json, workspace_context(opts))

    case llm_text(system_prompt(), prompt, opts) do
      {:ok, raw} -> parse_decision(raw)
      {:error, reason} -> {:flawed, reason}
    end
  end

  def verify(_objective, _tasks, _opts),
    do: {:flawed, "objective must be a string and tasks must be a list"}

  @spec parse_decision(String.t()) :: decision()
  def parse_decision(raw) when is_binary(raw) do
    with {:ok, decoded} <- decode_json(raw),
         {:ok, status} <- decision_status(decoded) do
      case status do
        :approved -> {:approved, decision_message(decoded, "reason", raw)}
        :flawed -> {:flawed, decision_message(decoded, "critique", raw)}
      end
    else
      {:error, reason} -> {:flawed, "Verifier returned invalid JSON: #{reason}"}
    end
  end

  def parse_decision(_raw), do: {:flawed, "Verifier output must be a string"}

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

  defp user_prompt(objective, plan_json, workspace_context) do
    """
    OBJECTIVE:
    #{objective}

    PROPOSED TASK ARRAY:
    #{plan_json}

    WORKSPACE CONTEXT:
    #{workspace_context}

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

  defp llm_text(system, user, opts) do
    context = %{
      system: system,
      messages: [%{role: :user, content: user}],
      objects: "",
      memory: %{}
    }

    case LLM.chat(llm_config(opts), context) do
      {:ok, %{content: content}} when is_binary(content) ->
        trimmed = String.trim(content)

        if trimmed == "" do
          {:error, "Verifier returned empty output"}
        else
          {:ok, trimmed}
        end

      {:error, reason} ->
        {:error, "Verifier LLM failed: #{inspect(reason)}"}
    end
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

  defp decode_json(raw) do
    text = raw |> String.trim() |> strip_code_fence()

    case Jason.decode(text) do
      {:ok, decoded} ->
        {:ok, decoded}

      _ ->
        case Regex.run(~r/\{[\s\S]*\}/, text) do
          [json] -> Jason.decode(json)
          _ -> {:error, "no JSON object found"}
        end
    end
  end

  defp strip_code_fence(text) do
    text
    |> String.replace(~r/\A```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```\z/, "")
    |> String.trim()
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

  defp drop_nil_values(map) do
    Map.new(map, fn {key, value} -> {key, value} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
