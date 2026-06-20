defmodule Mix.Tasks.Orchid.GvrRealGoalClosure do
  @moduledoc """
  Runs Orchid's GVR real-goal closure harness through the product GoalWatcher path.
  """

  use Mix.Task

  @shortdoc "Run the Orchid GVR real-goal closure harness"

  @impl Mix.Task
  def run(args) do
    Mix.Tasks.Orchid.RealGoalClosure.run_suite(:gvr, args)
  end
end
