# Boot one shared Bier instance for the conformance suite, then start ExUnit.
# Cases the harness can't evaluate yet (CLI, JWT signing, JSONPath, status-text
# reason phrase) are tagged :pending and excluded by default.
Bier.ConformanceServer.start!()

ExUnit.start(exclude: [:pending])
