defmodule Orchid.Planner.JSON do
  @moduledoc """
  Robust JSON extraction for planner LLM completions.

  Free models often return a valid JSON object or array followed by prose. This
  module extracts balanced JSON candidates from fenced or rambling text and
  decodes the first candidate matching the requested shape.
  """

  @type expected :: :any | :array | :object

  @spec extract_json(String.t(), expected()) :: {:ok, term()} | {:error, String.t()}
  def extract_json(raw, expected \\ :any)

  def extract_json(raw, expected) when is_binary(raw) and expected in [:any, :array, :object] do
    raw
    |> candidates()
    |> Enum.find_value(fn candidate ->
      case Jason.decode(candidate) do
        {:ok, decoded} ->
          if expected?(decoded, expected), do: {:ok, decoded}, else: nil

        {:error, _reason} ->
          nil
      end
    end)
    |> case do
      nil -> {:error, "no decodable JSON #{expected_label(expected)} found"}
      result -> result
    end
  end

  def extract_json(_raw, expected),
    do: {:error, "completion must be a string, expected #{expected_label(expected)}"}

  @spec render_error(term()) :: String.t()
  def render_error(term) when is_binary(term), do: term
  def render_error(%_{} = term), do: render_struct(term)
  def render_error(term), do: inspect(term)

  defp expected?(_decoded, :any), do: true
  defp expected?(decoded, :array), do: is_list(decoded)
  defp expected?(decoded, :object), do: is_map(decoded)

  defp expected_label(:array), do: "array"
  defp expected_label(:object), do: "object"
  defp expected_label(_expected), do: "value"

  defp render_struct(%module{} = term) do
    if function_exported?(module, :message, 1) do
      try do
        Exception.message(term)
      rescue
        _ -> inspect(term)
      end
    else
      inspect(term)
    end
  end

  defp candidates(raw) do
    text = raw |> String.trim() |> strip_outer_code_fence()

    [text | fenced_blocks(text)]
    |> Enum.flat_map(fn candidate -> [candidate | balanced_json_values(candidate)] end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp strip_outer_code_fence(text) do
    text
    |> String.replace(~r/\A```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```\z/, "")
    |> String.trim()
  end

  defp fenced_blocks(text) do
    ~r/```(?:json)?\s*([\s\S]*?)```/i
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [block] -> String.trim(block) end)
  end

  defp balanced_json_values(text) when is_binary(text) do
    scan_for_json_values(text, 0, [])
  end

  defp scan_for_json_values(text, offset, acc) when offset < byte_size(text) do
    rest = binary_part(text, offset, byte_size(text) - offset)

    case next_opener(rest) do
      {relative_start, opener} ->
        start = offset + relative_start

        case balanced_json_value_from(text, start, opener) do
          {:ok, json} -> scan_for_json_values(text, start + 1, acc ++ [json])
          :error -> scan_for_json_values(text, start + 1, acc)
        end

      :nomatch ->
        acc
    end
  end

  defp scan_for_json_values(_text, _offset, acc), do: acc

  defp next_opener(text) do
    object = :binary.match(text, "{")
    array = :binary.match(text, "[")

    case {object, array} do
      {:nomatch, :nomatch} -> :nomatch
      {{idx, 1}, :nomatch} -> {idx, ?{}
      {:nomatch, {idx, 1}} -> {idx, ?[}
      {{object_idx, 1}, {array_idx, 1}} when object_idx < array_idx -> {object_idx, ?{}
      {{_object_idx, 1}, {array_idx, 1}} -> {array_idx, ?[}
    end
  end

  defp balanced_json_value_from(text, start, opener) do
    closer = if opener == ?{, do: ?}, else: ?]
    scan_balanced_json_value(text, start + 1, start, [{opener, closer}], false, false)
  end

  defp scan_balanced_json_value(text, position, start, stack, in_string?, escape?)
       when position < byte_size(text) do
    byte = :binary.at(text, position)

    cond do
      in_string? and escape? ->
        scan_balanced_json_value(text, position + 1, start, stack, true, false)

      in_string? and byte == ?\\ ->
        scan_balanced_json_value(text, position + 1, start, stack, true, true)

      in_string? and byte == ?" ->
        scan_balanced_json_value(text, position + 1, start, stack, false, false)

      in_string? ->
        scan_balanced_json_value(text, position + 1, start, stack, true, false)

      byte == ?" ->
        scan_balanced_json_value(text, position + 1, start, stack, true, false)

      byte == ?{ ->
        scan_balanced_json_value(text, position + 1, start, [{?{, ?}} | stack], false, false)

      byte == ?[ ->
        scan_balanced_json_value(text, position + 1, start, [{?[, ?]} | stack], false, false)

      closing_top?(byte, stack) and length(stack) == 1 ->
        {:ok, binary_part(text, start, position - start + 1)}

      closing_top?(byte, stack) ->
        scan_balanced_json_value(text, position + 1, start, tl(stack), false, false)

      true ->
        scan_balanced_json_value(text, position + 1, start, stack, false, false)
    end
  end

  defp scan_balanced_json_value(_text, _position, _start, _stack, _in_string?, _escape?),
    do: :error

  defp closing_top?(_byte, []), do: false
  defp closing_top?(byte, [{_opener, closer} | _rest]), do: byte == closer
end
