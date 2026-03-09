defmodule Orchid.ProjectIntake do
  @moduledoc """
  Guides users through a new-project intake chat and keeps candidate fields updated.
  """

  @candidate_fields [
    :name,
    :objective,
    :success_criteria,
    :background,
    :constraints,
    :relevant_paths_text,
    :kickoff_goal
  ]

  @required_fields [:name, :objective, :success_criteria]
  @question_order [
    :objective,
    :success_criteria,
    :name,
    :background,
    :constraints,
    :relevant_paths_text,
    :kickoff_goal
  ]

  def initial_messages(form \\ %{}) do
    [%{role: :assistant, content: starter_message(form)}]
  end

  def starter_message(form \\ %{}) do
    form
    |> next_focus()
    |> question_for_focus()
  end

  def continue(messages, form, user_input, current_focus \\ nil)
      when is_list(messages) and is_map(form) and is_binary(user_input) do
    trimmed_input = String.trim(user_input)
    sanitized_form = sanitize_form(form)

    cond do
      trimmed_input == "" ->
        {:ok, fallback_response(sanitized_form, trimmed_input, current_focus)}

      true ->
        case backend().reply(messages, sanitized_form, trimmed_input, current_focus) do
          {:ok, response} ->
            {:ok, normalize_response(response, sanitized_form)}

          {:error, _reason} ->
            {:ok, fallback_response(sanitized_form, trimmed_input, current_focus)}
        end
    end
  rescue
    _ ->
      {:ok, fallback_response(sanitize_form(form), String.trim(user_input), current_focus)}
  end

  def ready_to_submit?(form) when is_map(form) do
    missing_fields(form) == []
  end

  def missing_fields(form) when is_map(form) do
    sanitized_form = sanitize_form(form)

    Enum.filter(@required_fields, fn field ->
      Map.get(sanitized_form, field, "") == ""
    end)
  end

  def next_focus(form) when is_map(form) do
    sanitized_form = sanitize_form(form)

    Enum.find(@question_order, fn field ->
      Map.get(sanitized_form, field, "") == ""
    end)
  end

  def field_label(:name), do: "project name"
  def field_label(:objective), do: "objective"
  def field_label(:success_criteria), do: "definition of done"
  def field_label(:background), do: "background"
  def field_label(:constraints), do: "constraints"
  def field_label(:relevant_paths_text), do: "repos, files, URLs, or assets"
  def field_label(:kickoff_goal), do: "suggested first goal"

  def field_label(field) when is_binary(field) do
    field
    |> String.replace("_", " ")
    |> String.trim()
  end

  def field_label(field), do: field |> to_string() |> field_label()

  def merge_candidate_fields(form, candidate_fields)
      when is_map(form) and is_map(candidate_fields) do
    base_form =
      Enum.reduce(@candidate_fields, form, fn field, acc ->
        Map.put(acc, field, normalize_candidate_value(Map.get(form, field), field))
      end)

    Enum.reduce(@candidate_fields, base_form, fn field, acc ->
      value =
        candidate_fields
        |> Map.get(field, Map.get(candidate_fields, Atom.to_string(field)))
        |> normalize_candidate_value(field)

      if value == "" do
        acc
      else
        Map.put(acc, field, value)
      end
    end)
  end

  def question_for_focus(:objective) do
    "What outcome should this project deliver?"
  end

  def question_for_focus(:success_criteria) do
    "How will we know this project is done? Describe the observable result."
  end

  def question_for_focus(:name) do
    "What short working name should we use for this project?"
  end

  def question_for_focus(:background) do
    "What background or prior context should the team know before starting?"
  end

  def question_for_focus(:constraints) do
    "What constraints or non-goals should Orchid respect?"
  end

  def question_for_focus(:relevant_paths_text) do
    "Which repos, files, URLs, or assets should this project start from?"
  end

  def question_for_focus(:kickoff_goal) do
    "What first goal should Orchid tackle once the project is created?"
  end

  def question_for_focus(nil) do
    "The brief looks ready. What would you like to tighten before submission?"
  end

  defp backend do
    Application.get_env(:orchid, :project_intake_backend, Orchid.ProjectIntake.LLMBackend)
  end

  defp sanitize_form(form) do
    Enum.reduce(@candidate_fields, %{}, fn field, acc ->
      Map.put(acc, field, normalize_candidate_value(Map.get(form, field), field))
    end)
  end

  defp normalize_response(response, form) when is_map(response) do
    merged_form =
      merge_candidate_fields(
        form,
        Map.get(response, :candidate_fields, Map.get(response, "candidate_fields", %{}))
      )

    assistant_message =
      response
      |> Map.get(:assistant_message, Map.get(response, "assistant_message"))
      |> normalize_text()
      |> case do
        "" -> question_for_focus(next_focus(merged_form))
        message -> message
      end

    %{
      assistant_message: assistant_message,
      candidate_fields: merged_form,
      ready_to_submit: ready_to_submit?(merged_form),
      missing_fields: missing_fields(merged_form),
      next_focus: next_focus(merged_form)
    }
  end

  defp fallback_response(form, user_input, current_focus) do
    updated_form =
      case current_focus do
        nil -> form
        field -> Map.put(form, field, normalize_candidate_value(user_input, field))
      end

    %{
      assistant_message: question_for_focus(next_focus(updated_form)),
      candidate_fields: updated_form,
      ready_to_submit: ready_to_submit?(updated_form),
      missing_fields: missing_fields(updated_form),
      next_focus: next_focus(updated_form)
    }
  end

  defp normalize_candidate_value(value, :relevant_paths_text) when is_list(value) do
    value
    |> Enum.map(&normalize_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp normalize_candidate_value(value, _field), do: normalize_text(value)

  defp normalize_text(nil), do: ""

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.trim()
  end

  defp normalize_text(value), do: value |> to_string() |> normalize_text()
end

defmodule Orchid.ProjectIntake.LLMBackend do
  @moduledoc false

  alias Orchid.{LLM, ProjectIntake}

  @llm_config %{
    provider: :cli,
    model: :sonnet,
    disable_tools: true,
    max_turns: 1,
    max_tokens: 1_200
  }
  @max_history_messages 12

  def reply(messages, form, user_input, current_focus)
      when is_list(messages) and is_map(form) and is_binary(user_input) do
    prompt = build_prompt(messages, form, user_input, current_focus)

    context = %{
      system: "",
      messages: [%{role: :user, content: prompt}],
      objects: "",
      memory: %{}
    }

    with {:ok, %{content: raw}} <- LLM.chat(@llm_config, context),
         {:ok, decoded} <- decode_json_blob(String.trim(raw)) do
      {:ok,
       %{
         assistant_message: decoded["assistant_message"],
         candidate_fields: decoded["candidate_fields"] || %{}
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  defp build_prompt(messages, form, user_input, current_focus) do
    """
    You are helping a user create a project brief for Orchid.

    Your job:
    - Maintain candidate fields for a new project.
    - Ask one concise Socratic follow-up question at a time.
    - Never invent facts the user did not provide.
    - Prefer clarifying the missing required fields first: objective, success_criteria, then name.
    - Treat repos, files, paths, and URLs as `relevant_paths_text`, joined with newlines.
    - Keep the assistant message to at most two sentences.

    Current priority focus: #{format_focus(current_focus)}

    Candidate fields JSON:
    #{Jason.encode!(form, pretty: true)}

    Conversation so far:
    #{format_history(messages, user_input)}

    Return ONLY valid JSON in this exact shape:
    {
      "assistant_message": "next question or concise synthesis",
      "candidate_fields": {
        "name": "",
        "objective": "",
        "success_criteria": "",
        "background": "",
        "constraints": "",
        "relevant_paths_text": "",
        "kickoff_goal": ""
      }
    }

    Leave unknown fields as their current values. Only update a field when the user provided evidence for it.
    """
    |> String.trim()
  end

  defp format_focus(nil), do: "none"
  defp format_focus(field), do: ProjectIntake.field_label(field)

  defp format_history(messages, user_input) do
    history =
      messages
      |> Enum.take(-@max_history_messages)
      |> Enum.map_join("\n", fn msg ->
        role =
          case msg[:role] || msg["role"] do
            :assistant -> "Assistant"
            :user -> "User"
            other -> other |> to_string() |> String.capitalize()
          end

        content = msg[:content] || msg["content"] || ""
        "#{role}: #{String.trim(content)}"
      end)

    [history, "User: #{String.trim(user_input)}"]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp decode_json_blob(text) when is_binary(text) and text != "" do
    case Jason.decode(text) do
      {:ok, parsed} ->
        {:ok, parsed}

      _ ->
        case Regex.run(~r/```(?:json)?\s*(\{.*\})\s*```/s, text, capture: :all_but_first) do
          [json] ->
            Jason.decode(json)

          _ ->
            case Regex.run(~r/\{.*\}/s, text) do
              [json] -> Jason.decode(json)
              _ -> {:error, :no_json_object_found}
            end
        end
    end
  end

  defp decode_json_blob(_), do: {:error, :empty_response}
end
