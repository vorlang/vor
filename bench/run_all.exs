# bench/run_all.exs
# Runs all Vor benchmarks in sequence
#
# Usage: mix run bench/run_all.exs

IO.puts("╔══════════════════════════════════════════════════════╗")
IO.puts("║           Vor Compiler Benchmark Suite               ║")
IO.puts("╚══════════════════════════════════════════════════════╝")
IO.puts("")

benchmarks = [
  {"Compilation Time", "bench/compile_time.exs"},
  {"Verification Time", "bench/verify_time.exs"},
  {"System Performance", "bench/system_perf.exs"}
]

for {name, path} <- benchmarks do
  IO.puts("━━━ Running: #{name} (#{path}) ━━━\n")
  Code.eval_file(path)
  IO.puts("")
end

IO.puts("Done.")
