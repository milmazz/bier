# Phase 2 Conformance Test Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the 532-case `spec/` tree into an initially-red ExUnit conformance suite: a generator emits one test per YAML case, all hitting one shared Bier instance over HTTP.

**Architecture:** Compile-time generator + a single shared Bier instance (no Postgres — Bier returns canned responses, so cases fail cleanly). A loader parses the YAML cases into structs; an `http_case` template performs the request via `req`; an assertions module interprets the `expect` block. CLI cases are tagged `:cli` and excluded.

**Tech Stack:** Elixir/ExUnit, `yaml_elixir` (parse cases), `req` (HTTP client), `excoveralls` (coverage). All test-only deps. Bier boots via `Bier.start_link/1`.

---

## File structure

| File | Responsibility |
| ---- | -------------- |
| `mix.exs` | add test-only deps + coverage config |
| `test/support/conformance_case.ex` | `Bier.ConformanceCase` struct + `load_all/0` (parse YAML) |
| `test/support/conformance_assertions.ex` | `Bier.ConformanceAssertions.assert_expect/2` |
| `test/support/conformance_server.ex` | `Bier.ConformanceServer` — boot one shared Bier instance, expose `base_url/0` |
| `test/support/http_case.ex` | `Bier.HttpCase` — `ExUnit.CaseTemplate`, `perform/1` (run a case over HTTP) |
| `test/conformance/conformance_test.exs` | `Bier.ConformanceTest` — the generator (one test per case) |
| `test/test_helper.exs` | boot the shared server; `ExUnit.start(exclude: [:cli])` |

Module naming: structs/helpers live under `Bier.*` in `test/support` (compiled only in `:test` per `mix.exs:25`).

---

## Task 1: Add test-only deps and coverage config

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add the three deps to `deps/0`**

In `mix.exs`, replace the `deps/0` list body with (keep existing entries, add the three `only: :test` deps):

```elixir
  defp deps do
    [
      {:bandit, "~> 1.0"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:nimble_options, "~> 1.0"},
      {:nimble_parsec, "~> 1.4"},
      {:plug, "~> 1.19"},
      {:yaml_elixir, "~> 2.11", only: :test},
      {:req, "~> 0.5", only: :test},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
```

- [ ] **Step 2: Add coverage config to `project/0`**

In the keyword list returned by `project/0` in `mix.exs`, add these two keys (anywhere in the list, e.g. after `elixirc_paths:`):

```elixir
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ],
```

- [ ] **Step 3: Fetch and compile**

Run: `mix deps.get && mix compile`
Expected: deps `yaml_elixir`, `req`, `excoveralls` (and transitive `jason`, `castore`, etc.) resolve and compile with no errors.

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "test: add yaml_elixir, req, excoveralls (test-only) for conformance suite"
```

---

## Task 2: ConformanceCase loader

**Files:**
- Create: `test/support/conformance_case.ex`
- Test: `test/bier/conformance_case_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/bier/conformance_case_test.exs`:

```elixir
defmodule Bier.ConformanceCaseTest do
  use ExUnit.Case, async: true

  alias Bier.ConformanceCase

  test "load_all/0 parses every YAML case into a struct" do
    cases = ConformanceCase.load_all()
    assert length(cases) > 500
    assert Enum.all?(cases, &match?(%ConformanceCase{}, &1))
    assert Enum.all?(cases, &is_integer(&1.id))
  end

  test "derives area from the feature prefix and defaults kind to :http" do
    c = Enum.find(ConformanceCase.load_all(), &(&1.id == 1067))
    assert c.feature == "operators/fts"
    assert c.area == "operators"
    assert c.kind == :http
    assert c.request["method"] == "GET"
    assert c.expect["status"] == 200
  end

  test "marks request.kind == cli cases as :cli" do
    c = Enum.find(ConformanceCase.load_all(), &(&1.id == 1705))
    assert c.kind == :cli
    assert c.request["flag"] == "--dump-config"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/conformance_case_test.exs`
Expected: FAIL — `Bier.ConformanceCase` is undefined.

- [ ] **Step 3: Implement the loader**

Create `test/support/conformance_case.ex`:

```elixir
defmodule Bier.ConformanceCase do
  @moduledoc """
  A parsed `spec/conformance/cases/*.yaml` record. `load_all/0` reads every case
  file into a struct; the conformance generator enumerates these.
  """

  @enforce_keys [:id, :feature, :area, :kind, :request, :expect]
  defstruct [:id, :feature, :area, :kind, :request, :schema, :preconditions, :expect, :source]

  @type t :: %__MODULE__{}

  # test/support -> project root -> spec/conformance/cases
  @cases_dir Path.expand("../../spec/conformance/cases", __DIR__)

  @spec cases_dir() :: String.t()
  def cases_dir, do: @cases_dir

  @spec load_all() :: [t()]
  def load_all do
    @cases_dir
    |> Path.join("*.yaml")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&load_file/1)
  end

  defp load_file(path) do
    data = YamlElixir.read_from_file!(path)
    request = Map.get(data, "request", %{})
    feature = Map.get(data, "feature", "")

    %__MODULE__{
      id: Map.fetch!(data, "id"),
      feature: feature,
      area: feature |> String.split("/") |> List.first(),
      kind: if(Map.get(request, "kind") == "cli", do: :cli, else: :http),
      request: request,
      schema: Map.get(data, "schema"),
      preconditions: Map.get(data, "preconditions", []),
      expect: Map.get(data, "expect", %{}),
      source: Map.get(data, "source")
    }
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/conformance_case_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add test/support/conformance_case.ex test/bier/conformance_case_test.exs
git commit -m "test: add ConformanceCase loader for spec YAML cases"
```

---

## Task 3: ConformanceAssertions

**Files:**
- Create: `test/support/conformance_assertions.ex`
- Test: `test/bier/conformance_assertions_test.exs`

The assertion target is a plain response map `%{status: integer, headers: %{String.t() => String.t()}, body: binary}`. Header keys are pre-downcased by the caller (Task 5).

- [ ] **Step 1: Write the failing test**

Create `test/bier/conformance_assertions_test.exs`:

```elixir
defmodule Bier.ConformanceAssertionsTest do
  use ExUnit.Case, async: true

  import Bier.ConformanceAssertions

  defp resp(overrides \\ %{}) do
    Map.merge(%{status: 200, headers: %{"content-type" => "application/json; charset=utf-8"}, body: ~s([{"a":1}])}, overrides)
  end

  test "status match passes, mismatch raises" do
    assert_expect(resp(), %{"status" => 200})
    assert_raise ExUnit.AssertionError, fn -> assert_expect(resp(), %{"status" => 404}) end
  end

  test "headers subset match" do
    assert_expect(resp(), %{"headers" => %{"Content-Type" => "application/json; charset=utf-8"}})
    assert_raise ExUnit.AssertionError, fn ->
      assert_expect(resp(), %{"headers" => %{"Content-Type" => "text/csv"}})
    end
  end

  test "headers_present and headers_absent" do
    assert_expect(resp(), %{"headers_present" => ["Content-Type"]})
    assert_expect(resp(), %{"headers_absent" => ["Location"]})
    assert_raise ExUnit.AssertionError, fn -> assert_expect(resp(), %{"headers_present" => ["Location"]}) end
  end

  test "body_exact deep-compares decoded JSON" do
    assert_expect(resp(), %{"body_exact" => [%{"a" => 1}]})
    assert_raise ExUnit.AssertionError, fn -> assert_expect(resp(), %{"body_exact" => [%{"a" => 2}]}) end
  end

  test "body_contains substring; body_raw exact bytes" do
    assert_expect(resp(), %{"body_contains" => ~s("a":1)})
    assert_expect(resp(%{body: <<1>> <> ~s({"type": "FeatureCollection"})}), %{"body_raw" => <<1>> <> ~s({"type": "FeatureCollection"})})
  end

  test "unknown assertion key raises (never silently passes)" do
    assert_raise RuntimeError, ~r/unsupported assertion/, fn ->
      assert_expect(resp(), %{"body_nonsense" => 1})
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/conformance_assertions_test.exs`
Expected: FAIL — `Bier.ConformanceAssertions` undefined.

- [ ] **Step 3: Implement the assertions**

Create `test/support/conformance_assertions.ex`:

```elixir
defmodule Bier.ConformanceAssertions do
  @moduledoc """
  Interprets a conformance case's `expect` block against a normalized response
  map `%{status:, headers:, body:}` (header keys pre-downcased).
  """
  import ExUnit.Assertions

  @doc "Assert every key of `expect` holds for `resp`. Unknown keys raise."
  def assert_expect(resp, expect) when is_map(expect) do
    Enum.each(expect, fn {key, val} -> check(key, val, resp) end)
  end

  defp check("status", expected, resp) do
    assert resp.status == expected,
           "expected status #{expected}, got #{resp.status}"
  end

  defp check("headers", map, resp) when is_map(map) do
    Enum.each(map, fn {name, value} ->
      actual = Map.get(resp.headers, String.downcase(name))
      assert actual == value,
             "header #{name}: expected #{inspect(value)}, got #{inspect(actual)}"
    end)
  end

  defp check("headers_present", names, resp) when is_list(names) do
    Enum.each(names, fn name ->
      assert Map.has_key?(resp.headers, String.downcase(name)),
             "expected header #{name} to be present"
    end)
  end

  defp check("headers_absent", names, resp) when is_list(names) do
    Enum.each(names, fn name ->
      refute Map.has_key?(resp.headers, String.downcase(name)),
             "expected header #{name} to be absent"
    end)
  end

  defp check(key, expected, resp) when key in ["body_exact", "body_json"] do
    actual = decode_json(resp.body)
    assert actual == expected,
           "#{key} mismatch:\n  expected: #{inspect(expected)}\n  got:      #{inspect(actual)}"
  end

  defp check("body_contains", expected, resp) do
    needles = List.wrap(expected)
    Enum.each(needles, fn needle ->
      assert is_binary(needle) and String.contains?(resp.body, needle),
             "body did not contain #{inspect(needle)}"
    end)
  end

  defp check("body_raw", expected, resp) do
    assert resp.body == expected,
           "body_raw mismatch:\n  expected: #{inspect(expected)}\n  got:      #{inspect(resp.body)}"
  end

  defp check(key, _val, _resp) do
    raise "unsupported assertion key: #{inspect(key)}"
  end

  defp decode_json(body) do
    Bier.json_library().decode!(body)
  rescue
    _ -> flunk("response body was not valid JSON: #{inspect(body)}")
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/conformance_assertions_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add test/support/conformance_assertions.ex test/bier/conformance_assertions_test.exs
git commit -m "test: add ConformanceAssertions for the expect vocabulary"
```

---

## Task 4: ConformanceServer (shared Bier instance)

**Files:**
- Create: `test/support/conformance_server.ex`
- Test: `test/bier/conformance_server_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/bier/conformance_server_test.exs`:

```elixir
defmodule Bier.ConformanceServerTest do
  use ExUnit.Case, async: true

  test "base_url/0 returns the running instance URL and it answers HTTP" do
    base = Bier.ConformanceServer.base_url()
    assert base =~ ~r{^http://127\.0\.0\.1:\d+$}

    # Unknown path -> Bier returns *some* response (canned/404), proving it's up.
    resp = Req.request!(method: :get, url: base <> "/__definitely_unknown__", retry: false)
    assert is_integer(resp.status)
  end
end
```

(The server is started once in `test_helper.exs` — Task 6. This test asserts it is reachable.)

- [ ] **Step 2: Implement the server module**

Create `test/support/conformance_server.ex`:

```elixir
defmodule Bier.ConformanceServer do
  @moduledoc """
  Boots ONE shared Bier instance for the conformance suite and exposes its
  base URL. Started in test_helper.exs before ExUnit.start/1.
  """

  @instance __MODULE__.Instance
  @key {__MODULE__, :base_url}

  @doc "Start the shared instance on a free port and remember its base URL."
  def start! do
    port = free_port()
    {:ok, _pid} = Bier.start_link(name: @instance, router: [port: port, scheme: :http])
    base = "http://127.0.0.1:#{port}"
    wait_until_listening(port)
    :persistent_term.put(@key, base)
    base
  end

  @doc "Base URL of the shared instance (e.g. \"http://127.0.0.1:54321\")."
  def base_url, do: :persistent_term.get(@key)

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp wait_until_listening(port, retries \\ 100) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 50) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _} when retries > 0 ->
        Process.sleep(20)
        wait_until_listening(port, retries - 1)

      {:error, reason} ->
        raise "Bier conformance server did not come up on port #{port}: #{inspect(reason)}"
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails (server not started yet)**

Run: `mix test test/bier/conformance_server_test.exs`
Expected: FAIL — `:persistent_term.get/1` raises `ArgumentError` because nothing has called `start!/0` yet (wired in Task 6). This confirms the module compiles and the test exercises the not-yet-booted path.

- [ ] **Step 4: Commit**

```bash
git add test/support/conformance_server.ex test/bier/conformance_server_test.exs
git commit -m "test: add ConformanceServer (shared Bier instance on a free port)"
```

(The server test goes green in Task 6 once `test_helper.exs` boots it.)

---

## Task 5: HttpCase (perform a case over HTTP)

**Files:**
- Create: `test/support/http_case.ex`
- Test: `test/bier/http_case_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/bier/http_case_test.exs`:

```elixir
defmodule Bier.HttpCaseTest do
  use Bier.HttpCase, async: true

  alias Bier.ConformanceCase

  test "perform/1 issues the request and returns a normalized response" do
    c = %ConformanceCase{
      id: 0,
      feature: "smoke/get",
      area: "smoke",
      kind: :http,
      request: %{"method" => "GET", "path" => "/__unknown__", "headers" => %{"Accept" => "application/json"}},
      schema: "test",
      preconditions: [],
      expect: %{},
      source: nil
    }

    resp = perform(c)
    assert is_integer(resp.status)
    assert is_map(resp.headers)
    assert Enum.all?(Map.keys(resp.headers), &(&1 == String.downcase(&1)))
    assert is_binary(resp.body)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/http_case_test.exs`
Expected: FAIL — `Bier.HttpCase` undefined.

- [ ] **Step 3: Implement the case template**

Create `test/support/http_case.ex`:

```elixir
defmodule Bier.HttpCase do
  @moduledoc """
  ExUnit case template for conformance tests. Provides `perform/1`, which runs a
  `Bier.ConformanceCase` against the shared Bier instance and returns a
  normalized `%{status:, headers:, body:}` map (header keys downcased), plus the
  assertion helpers.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Bier.HttpCase
      import Bier.ConformanceAssertions
    end
  end

  @doc "Run an HTTP conformance case against the shared instance."
  def perform(%Bier.ConformanceCase{request: req, schema: schema}) do
    method = req |> Map.get("method", "GET") |> String.downcase() |> String.to_atom()
    url = Bier.ConformanceServer.base_url() <> Map.fetch!(req, "path")

    resp =
      Req.request!(
        method: method,
        url: url,
        headers: build_headers(req, schema),
        body: encode_body(Map.get(req, "body")),
        decode_body: false,
        retry: false
      )

    %{status: resp.status, headers: normalize_headers(resp.headers), body: resp.body || ""}
  end

  defp build_headers(req, schema) do
    base = Map.get(req, "headers", %{})
    # Map the case's schema to Accept-Profile so cases are future-correct when
    # Bier supports schema routing. "public"/nil is the default; don't send it.
    if schema in [nil, "public", "test"] do
      base
    else
      Map.put_new(base, "Accept-Profile", schema)
    end
  end

  defp encode_body(nil), do: nil
  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body), do: Bier.json_library().encode!(body)

  # Req returns headers as %{"name" => [values]} with downcased names.
  defp normalize_headers(headers) do
    Map.new(headers, fn {k, v} -> {String.downcase(k), v |> List.wrap() |> Enum.join(", ")} end)
  end
end
```

- [ ] **Step 4: Run test to verify it fails for a new reason (server not booted)**

Run: `mix test test/bier/http_case_test.exs`
Expected: FAIL — raises in `Bier.ConformanceServer.base_url/0` (`:persistent_term` not set). This confirms `perform/1` compiles and reaches the HTTP layer; it goes green in Task 6.

- [ ] **Step 5: Commit**

```bash
git add test/support/http_case.ex test/bier/http_case_test.exs
git commit -m "test: add HttpCase template with perform/1"
```

---

## Task 6: Wire the shared server + generate the conformance suite

**Files:**
- Modify: `test/test_helper.exs`
- Create: `test/conformance/conformance_test.exs`

- [ ] **Step 1: Boot the shared server in test_helper**

Replace the contents of `test/test_helper.exs` with:

```elixir
# Boot one shared Bier instance for the conformance suite, then start ExUnit.
# CLI cases (config dump, observability flags) have no execution target yet, so
# they are excluded by default and tracked as pending.
Bier.ConformanceServer.start!()

ExUnit.start(exclude: [:cli])
```

- [ ] **Step 2: Run the support-module tests — they should now pass**

Run: `mix test test/bier/conformance_server_test.exs test/bier/http_case_test.exs`
Expected: PASS — the server is up, `base_url/0` returns a URL, and `perform/1` gets a real response.

- [ ] **Step 3: Write the generator**

Create `test/conformance/conformance_test.exs`:

```elixir
defmodule Bier.ConformanceTest do
  @moduledoc """
  One ExUnit test per spec conformance case. HTTP cases run against the shared
  Bier instance and currently FAIL (lib/ returns canned responses). CLI cases
  are tagged :cli and excluded until a Bier CLI exists.
  """
  use Bier.HttpCase, async: true

  @moduletag :conformance

  for c <- Bier.ConformanceCase.load_all() do
    @case Macro.escape(c)

    case c.kind do
      :http ->
        @tag area: String.to_atom(c.area)
        test "#{c.id} #{c.feature}" do
          resp = perform(@case)
          assert_expect(resp, @case.expect)
        end

      :cli ->
        @tag :cli
        @tag :pending
        @tag area: String.to_atom(c.area)
        test "#{c.id} #{c.feature} (cli, pending)" do
          # No Bier CLI entrypoint yet; recorded as pending. See COVERAGE.md.
          flunk("CLI conformance case #{@case.id} has no execution target yet")
        end
    end
  end
end
```

- [ ] **Step 4: Run the whole suite — expect it RED but clean**

Run: `mix test`
Expected:
- The suite runs to completion (no compile errors, no crashes).
- Unit tests (ConformanceCase, ConformanceAssertions, ConformanceServer, HttpCase, existing `bier_test`, `query_parser_test`) **pass**.
- ~500 HTTP conformance tests **fail** on assertion mismatches (canned response ≠ expected).
- CLI conformance tests are **excluded** (not run), via `exclude: [:cli]` in `test_helper.exs`.
- Output ends with a failures summary and `0` invalid/errors (only assertion failures).

> Note: use plain `mix test`, NOT `mix test --only conformance`. Under `--only conformance` the include tag matches the CLI tests too (they carry the `:conformance` module tag), overriding the `:cli` exclude — they would run and flunk. Plain `mix test` is what excludes them.

- [ ] **Step 5: Commit**

```bash
git add test/test_helper.exs test/conformance/conformance_test.exs
git commit -m "test: generate conformance suite (one test per spec case), boot shared server"
```

---

## Task 7: Coverage check + verification of exit criteria

**Files:** none (verification only)

- [ ] **Step 1: Confirm the area filter works (for Phase 3 devs)**

Run: `mix test --only area:operators`
Expected: only `operators` conformance cases run (all failing); the rest are excluded.

- [ ] **Step 2: Run coverage on the test infrastructure**

Run: `mix coveralls`
Expected: a coverage report is produced. The conformance support modules
(`ConformanceCase`, `ConformanceAssertions`, `HttpCase`, `ConformanceServer`)
should report high line coverage (≥ 90%) because every case exercises them.

- [ ] **Step 3: Record the case/failure counts**

Run: `mix test 2>&1 | tail -5`
Expected: note the totals (tests run, failures, excluded). Failures ≈ number of HTTP cases; excluded ≈ number of CLI cases. These are the §5.2 exit numbers. (Plain `mix test`, not `--only conformance` — see the note in Task 6 Step 4.)

- [ ] **Step 4: Update CHANGELOG (if present) / final commit**

If `CHANGELOG.md` exists, add an entry under `## [Unreleased]` → `### Tests`:
`- Add spec-driven conformance suite (532 cases) running red against stubbed lib/.`
Then:

```bash
git add -A
git commit -m "test: phase 2 conformance suite green-on-infra, red-on-cases"
```

If `CHANGELOG.md` does not exist, skip the file edit and only commit if there are uncommitted changes; otherwise this task is verification-only and needs no commit.

---

## Notes for the implementer

- **No Postgres.** Bier never queries a DB in this phase; do not add `postgres_case` or fixture loading. Cases are red because `lib/` returns canned responses — that is intended.
- **Do not weaken assertions to make cases pass.** Per §3.3 of `docs/AGENT_PLAN.md`, only a corrected spec authorizes a test change. The suite is supposed to be red now.
- **`async: true` is safe** because the shared instance is stateless (no DB, read-only canned responses).
- **Header keys are downcased** by `normalize_headers/1`; `ConformanceAssertions` downcases expected header names to match.
- If `mix test` reports *errors* (not failures) — e.g. a case whose `expect` uses an unhandled key — that key surfaces via the `unsupported assertion key` raise; add a clause to `ConformanceAssertions` only if the key is legitimately in `spec/case.schema.json`.
