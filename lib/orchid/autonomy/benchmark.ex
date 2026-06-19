defmodule Orchid.Autonomy.Benchmark do
  @moduledoc """
  Static benchmark specification for the autonomy metric suite.

  A benchmark describes one unattended goal, the deterministic sandbox check
  that decides closure, and the limits used by the runner. The struct is data
  only; scoring and execution live in `Orchid.Autonomy.Runner` and
  `Orchid.Autonomy.Scorer`.
  """

  @enforce_keys [:id, :objective, :success_check, :max_steps, :category]
  defstruct @enforce_keys

  @type category :: :research | :development | :operation

  @type success_check ::
          {:shell, String.t()}
          | {:file_exists, String.t()}
          | {:file_contains, String.t(), String.t() | Regex.t()}
          | {:predicate, (map() -> boolean())}

  @type t :: %__MODULE__{
          id: String.t(),
          objective: String.t(),
          success_check: success_check(),
          max_steps: pos_integer(),
          category: category()
        }

  @doc """
  Build and validate a benchmark from a map or keyword list.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    attrs
    |> then(&struct(__MODULE__, &1))
    |> validate()
  end

  @doc """
  Build a benchmark or raise an `ArgumentError`.
  """
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, benchmark} -> benchmark
      {:error, reason} -> raise ArgumentError, "invalid autonomy benchmark: #{inspect(reason)}"
    end
  end

  @doc """
  True when the category is one of the autonomy suite's accepted domains.
  """
  @spec valid_category?(term()) :: boolean()
  def valid_category?(category), do: category in [:research, :development, :operation]

  defp validate(%__MODULE__{} = benchmark) do
    cond do
      not string_present?(benchmark.id) ->
        {:error, {:invalid_id, benchmark.id}}

      not string_present?(benchmark.objective) ->
        {:error, {:invalid_objective, benchmark.objective}}

      not valid_success_check?(benchmark.success_check) ->
        {:error, {:invalid_success_check, benchmark.success_check}}

      not (is_integer(benchmark.max_steps) and benchmark.max_steps > 0) ->
        {:error, {:invalid_max_steps, benchmark.max_steps}}

      not valid_category?(benchmark.category) ->
        {:error, {:invalid_category, benchmark.category}}

      true ->
        {:ok, benchmark}
    end
  end

  defp string_present?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_success_check?({:shell, command}), do: string_present?(command)
  defp valid_success_check?({:file_exists, path}), do: string_present?(path)

  defp valid_success_check?({:file_contains, path, needle}) do
    string_present?(path) and (is_binary(needle) or match?(%Regex{}, needle))
  end

  defp valid_success_check?({:predicate, predicate}), do: is_function(predicate, 1)
  defp valid_success_check?(_success_check), do: false
end
