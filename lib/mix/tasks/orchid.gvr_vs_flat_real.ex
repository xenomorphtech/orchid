defmodule Mix.Tasks.Orchid.GvrVsFlatReal do
  @moduledoc """
  Runs one real goal through forced flat and G-V-R planner modes.
  """

  use Mix.Task

  @shortdoc "Run the Orchid G-V-R versus flat real-goal A/B harness"

  @impl Mix.Task
  def run(args) do
    Mix.Tasks.Orchid.RealGoalClosure.run_gvr_vs_flat(args)
  end
end
