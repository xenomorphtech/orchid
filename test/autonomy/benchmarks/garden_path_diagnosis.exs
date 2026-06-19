alias Orchid.Autonomy.Benchmark

# Planning gap: README and the obvious config value point at cache size, a
# plausible but wrong diagnosis. A flat greedy loop is likely to "fix" the cache
# knob first and fail the check; a planner cross-checks logs against config,
# rejects the cache hypothesis, and repairs the token-audience mismatch while
# preserving the untouched cache settings.
Benchmark.new!(%{
  id: "garden_path_diagnosis",
  objective: """
  Diagnose the seeded API incident in `/workspace`. The README contains a
  plausible cache-size hypothesis, but you must verify it against the logs before
  changing config. Apply only the actual fix, preserve unrelated cache settings,
  and write `ops/diagnosis.txt` with the root cause, rejected hypothesis, and
  verification evidence.
  """,
  success_check:
    {:shell,
     """
     cd /workspace &&
     grep -q '^TOKEN_AUDIENCE=orchid-api$' config/auth.env &&
     grep -q '^JWKS_CACHE_TTL_SECONDS=300$' config/auth.env &&
     grep -q '^CACHE_SIZE_MB=64$' config/cache.env &&
     grep -q '^CACHE_EVICTION=lfu$' config/cache.env &&
     test -f ops/diagnosis.txt &&
     grep -Eiq '^root_cause:.*token audience.*(mobile|orchid-api)' ops/diagnosis.txt &&
     grep -Eiq '^rejected_hypothesis:.*cache' ops/diagnosis.txt &&
     grep -Eiq '^verification:.*(invalid_audience|401|orchid-api)' ops/diagnosis.txt
     """},
  max_steps: 24,
  category: :operation,
  seed_files: [
    %{
      path: "README.md",
      content: """
      # API Latency Incident

      The dashboard says checkout-api p95 rose after the noon deploy. The most
      obvious suspect is the cache config because `CACHE_SIZE_MB=64` is below
      the usual 128 MB default. Operators often start by raising this value.

      Do not change config until the logs confirm the hypothesis. Record the
      diagnosis in ops/diagnosis.txt using these keys:

      root_cause
      rejected_hypothesis
      verification
      """
    },
    %{
      path: "config/cache.env",
      content: """
      CACHE_SIZE_MB=64
      CACHE_EVICTION=lfu
      CACHE_NAMESPACE=checkout-api
      """
    },
    %{
      path: "config/auth.env",
      content: """
      TOKEN_AUDIENCE=mobile
      JWKS_CACHE_TTL_SECONDS=300
      ISSUER=https://auth.example.test/
      """
    },
    %{
      path: "logs/dashboard.log",
      content: """
      2026-06-18T12:02:00Z p95_ms=820 route=/checkout service=checkout-api region=us-east-2
      2026-06-18T12:03:00Z cache_hit_rate=0.99 cache_evictions=0 cache_namespace=checkout-api
      2026-06-18T12:04:00Z upstream_401_rate=0.42 auth_failures=38
      2026-06-18T12:05:00Z p95_ms=835 route=/checkout service=checkout-api region=us-east-2
      """
    },
    %{
      path: "logs/api.log",
      content: """
      2026-06-18T12:03:11Z checkout-api warn invalid_audience expected=orchid-api actual=mobile request_id=req-101
      2026-06-18T12:03:17Z checkout-api warn invalid_audience expected=orchid-api actual=mobile request_id=req-102
      2026-06-18T12:03:28Z checkout-api info cache_lookup result=hit key=pricing:standard latency_ms=2
      2026-06-18T12:04:02Z checkout-api warn invalid_audience expected=orchid-api actual=mobile request_id=req-103
      2026-06-18T12:04:44Z checkout-api info cache_lookup result=hit key=tax:east latency_ms=1
      """
    },
    %{
      path: "ops/diagnosis.txt",
      content: """
      root_cause:
      rejected_hypothesis:
      verification:
      """
    }
  ]
})
