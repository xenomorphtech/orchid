alias Orchid.Autonomy.Benchmark

Benchmark.new!(%{
  id: "research_incident_summary",
  objective: """
  Analyze the seeded evidence files and write `report/findings.txt` with these exact
  keys on separate lines: `source_ip`, `endpoint`, `token`, and `status`. Use the
  suspicious successful admin export request as the source of truth.
  """,
  success_check:
    {:shell,
     """
     cd /workspace &&
     test -f report/findings.txt &&
     grep -Eq 'source_ip:[[:space:]]*203\\.0\\.113\\.42' report/findings.txt &&
     grep -Eq 'endpoint:[[:space:]]*/admin/export' report/findings.txt &&
     grep -Eq 'token:[[:space:]]*orchid-canary-17' report/findings.txt &&
     grep -Eq 'status:[[:space:]]*200' report/findings.txt
     """},
  max_steps: 20,
  category: :research,
  seed_files: [
    %{
      path: "evidence/access.log",
      content: """
      2026-06-18T09:15:01Z source=198.51.100.10 method=GET path=/login status=200 token=none
      2026-06-18T09:16:44Z source=203.0.113.42 method=GET path=/admin/export status=200 token=orchid-canary-17 bytes=4812
      2026-06-18T09:17:02Z source=192.0.2.55 method=GET path=/admin/export status=403 token=invalid
      2026-06-18T09:18:11Z source=198.51.100.10 method=GET path=/logout status=204 token=none
      """
    },
    %{
      path: "evidence/notes.md",
      content: """
      The report should identify the successful suspicious admin export request.
      Ignore failed requests and normal login/logout traffic.
      """
    }
  ]
})
