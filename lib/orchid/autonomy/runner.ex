defmodule Orchid.Autonomy.Runner do
  @moduledoc """
  Unattended benchmark runner for the autonomy metric suite.

  The runner owns the future end-to-end flow:

    * create or reset a sandboxed project for a benchmark
    * create an agent with interventions disabled
    * drive the benchmark objective until closure, stall, or `max_steps`
    * return a deterministic run result for the scorer

  This scaffold exposes the contract without launching an agent yet.
  """

  alias Orchid.Autonomy.Benchmark

  @type step :: %{
          optional(:index) => non_neg_integer(),
          optional(:status) => atom(),
          optional(:summary) => String.t(),
          optional(:max_steps) => pos_integer()
        }

  @type recovery_event :: %{
          optional(:step) => non_neg_integer(),
          optional(:status) => atom(),
          optional(:reason) => term(),
          optional(:recovered) => boolean()
        }

  @type run_result :: %{
          required(:benchmark) => Benchmark.t(),
          required(:project_id) => String.t() | nil,
          required(:depth) => non_neg_integer(),
          required(:closed) => boolean(),
          required(:recovered) => [recovery_event()],
          required(:steps) => [step()],
          optional(:agent_id) => String.t(),
          optional(:status) => atom(),
          optional(:error) => term()
        }

  @type option ::
          {:project_id, String.t()}
          | {:agent_config, map()}
          | {:max_steps, pos_integer()}
          | {:wall_clock_timeout_ms, pos_integer()}

  @doc """
  Run a benchmark unattended.

  The current scaffold returns a non-closing result with depth `0`. The next
  implementation step is to wire this function to `Orchid.Projects`,
  `Orchid.Goals`, and `Orchid.Agent`.
  """
  @spec run(Benchmark.t(), [option()]) :: {:ok, run_result()} | {:error, term()}
  def run(%Benchmark{} = benchmark, opts \\ []) when is_list(opts) do
    max_steps = Keyword.get(opts, :max_steps, benchmark.max_steps)

    if is_integer(max_steps) and max_steps > 0 do
      {:ok,
       %{
         benchmark: benchmark,
         project_id: Keyword.get(opts, :project_id),
         depth: 0,
         closed: false,
         recovered: [],
         steps: [
           %{
             index: 0,
             status: :not_implemented,
             summary: "Runner scaffold only; unattended agent loop wiring is TODO.",
             max_steps: max_steps
           }
         ],
         status: :scaffold
       }}
    else
      {:error, {:invalid_max_steps, max_steps}}
    end
  end
end
