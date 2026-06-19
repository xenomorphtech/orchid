alias Orchid.Autonomy.Benchmark

Benchmark.new!(%{
  id: "build_cli_wordcount",
  objective: "Write a CLI that counts words in a file and passes its own tests.",
  success_check: {:shell, "cd /workspace && mix test 2>&1 | grep -q '0 failures'"},
  max_steps: 40,
  category: :development
})
