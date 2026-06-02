# Boot one shared Bier instance for the conformance suite, then start ExUnit.
# CLI cases (config dump, observability flags) have no execution target yet, so
# they are excluded by default and tracked as pending.
Bier.ConformanceServer.start!()

ExUnit.start(exclude: [:cli])
