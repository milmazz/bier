# Boot one shared Bier instance for the conformance suite, then start ExUnit.
# Cases the harness can't evaluate yet (CLI, JWT signing, JSONPath, status-text
# reason phrase) are tagged :pending and excluded by default.
Bier.ConformanceServer.start!()

# Pin the test HTTP client to HTTP/1.1 for the whole suite. PostgREST's
# reference suite runs over HTTP/1, and under `async: true` Finch's HTTP/2 path
# intermittently raises `http2 error: :pool_not_available` (a single-connection
# pool race) — flaking unrelated requests. HTTP/1 uses per-connection pools and
# is deterministic. Applies globally to every `Req` call (perform/1 and the
# harness's own probes).
Req.default_options(connect_options: [protocols: [:http1]])

ExUnit.start(exclude: [:pending])
