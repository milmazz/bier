# Issue #85 OpenAPI Root-Document Wire Gaps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close all three items of GitHub issue #85 — the root `"/"` path item, the RPC operation `produces` list, and the default `schemes`/`host`/`basePath` block when no `openapi-server-proxy-uri` is configured.

**Architecture:** All three are pure wire-format changes inside `Bier.OpenAPI.build/1` (the Swagger 2.0 emitter), cited line-by-line to PostgREST v14.12 `src/PostgREST/Response/OpenAPI.hs`. Item 3 additionally threads the instance's `server_host` / `router[:scheme]` / `router[:port]` from `Bier.Plugs.ActionController.build_openapi_document/2` into the emitter input, and replaces the proxy-only `host`/`schemes` logic with the unconditional block PostgREST emits (`postgrestSpec` always receives scheme/host/port/basePath — `proxyUri` falls back to server config).

**Tech Stack:** Elixir (~> 1.18 floor, 1.20 pinned), ExUnit.

## Global Constraints

- Never edit anything under `spec/` or `test/support/` or `test/conformance/` — frozen conformance ground truth (CLAUDE.md). Unit tests under `test/bier/` are NOT frozen and may be corrected when the change is justified by a cited PostgREST v14.12 source line; every such correction below carries its citation.
- All conformance cases must keep passing: `mix test` (requires local PostgreSQL; drops+recreates `bier_test`).
- Wire-parity authority: `https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/src/PostgREST/Response/OpenAPI.hs` (cited as `OpenAPI.hs#L<n>`), plus `Network.hs#L46-52` (`escapeHostName`), `MediaType.hs#L72-74` (`toMime`), and swagger2's `ToJSON Host` (`Data.Swagger.Internal`, `Host h (Just p)` → `"h:p"`).
- `mix precommit` (deps.unlock check, format, hex.audit, compile --warnings-as-errors, credo --strict, docs, test) must pass before the branch is done.
- Execute on a fresh branch off `main` (suggested: `openapi-85-wire-gaps`).
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Verified-safe against the frozen suite:** every OpenAPI-document conformance case (1650–1682, 1619–1621) asserts via `body_jsonpath` (targeted paths), never whole-document equality, and no `absent:` predicate targets `$.paths['/']`, `produces`, `host`, or `schemes` (checked via `grep -rn "absent" spec/conformance/cases/16*.yaml`). Adding keys cannot break them.

**Source facts this plan relies on (all verified in the fetched v14.12 sources):**

- `makeRootPathItem` (OpenAPI.hs#L370-379): path `"/"` carries only a GET op with `tags: ["Introspection"]`, `summary: "OpenAPI description (this document)"`, `produces: [application/openapi+json, application/json]`, responses `200 → "OK"`. It is inserted first by `makePathItems` (L381-383).
- RPC ops (OpenAPI.hs#L356-368): `procOp` — shared by GET and POST — carries `produces ?~ makeMimeList [MTApplicationJSON, MTVndSingularJSON True, MTVndSingularJSON False]`; `toMime` (MediaType.hs#L72-74) renders those as `application/json`, `application/vnd.pgrst.object+json;nulls=stripped`, `application/vnd.pgrst.object+json`.
- `proxyUri` (OpenAPI.hs#L448-454): with no proxy configured the spec is built from `("http", configServerHost, toInteger configServerPort, "/")`. `postgrestSpec` (L393-414) then **unconditionally** emits `basePath`, `schemes [s']` (`Http` when `"http"`, else `Https`), and `host = Host (escapeHostName h) (Just p)` — the port is ALWAYS present, including for proxy URIs with scheme-default ports (`pickProxy` L441-446 fills 80/443). swagger2 serializes `Host h (Just p)` as `"h:p"`.
- `escapeHostName` (Network.hs#L46-52): `"*"`, `"*4"`, `"!4"`, `"*6"`, `"!6"` all map to `"0.0.0.0"`; anything else passes through.
- PostgREST hardcodes scheme `"http"` in the no-proxy fallback because it has no native TLS; Bier serves `:https` via Bandit, so the no-proxy scheme comes from `router[:scheme]` (defaults to `:http`, matching PostgREST's default wire output).
- Bier config surface (already exists, nothing new): `server_host` (default `"!4"`, `lib/bier.ex` ~L126), `router[:scheme]` (default `:http`) and `router[:port]` (default 4040, always a pos_integer).

**Known deviation this plan REMOVES:** Bier's current `with_proxy/2` omits scheme-default ports from `host` ("example.com", not "example.com:80"). Real v14.12 always appends the port (OpenAPI.hs#L414 + L441-446). The existing unit test asserting the omission is corrected with that citation.

---

### Task 1: Root `"/"` path item + RPC `produces` list

Issue #85 items 1 and 2. Both are additive keys inside `paths`, so they share one test cycle.

**Files:**
- Modify: `lib/bier/openapi.ex` (`paths/1` ~L83-86, `function_path_item/1` ~L105-137)
- Test: `test/bier/openapi_test.exs` (rpc describe ~L578-700; new describe for the root item)

**Interfaces:**
- Consumes: nothing new — pure change inside `Bier.OpenAPI.build/1`.
- Produces: unchanged signature `Bier.OpenAPI.build(input :: map()) :: map()`. Task 3 edits the same file — do Task 1 first, commit, then Task 3.

- [ ] **Step 1: Write the failing tests**

In `test/bier/openapi_test.exs`, append a new describe after the `"build/1 proxy (openapi-server-proxy-uri)"` block:

```elixir
  describe "root introspection path item" do
    # PostgREST inserts a "/" path item first (makeRootPathItem,
    # OpenAPI.hs#L370-383): GET-only, Introspection tag, and a produces
    # pair of openapi+json / json (toMime, MediaType.hs#L72). Issue #85.
    test "GET-only / entry with Introspection tag and produces pair" do
      doc = build_fns([])

      assert doc["paths"]["/"] == %{
               "get" => %{
                 "tags" => ["Introspection"],
                 "summary" => "OpenAPI description (this document)",
                 "produces" => ["application/openapi+json", "application/json"],
                 "responses" => %{"200" => %{"description" => "OK"}}
               }
             }
    end
  end
```

And in the `"rpc path items (1670-1674)"` describe, add one test after `"volatility methods (1674)"`:

```elixir
    test "get and post ops carry the rpc produces list (issue #85)", %{doc: doc} do
      # Every RPC operation advertises json + both singular-object variants
      # (procOp produces, OpenAPI.hs#L360; mime strings MediaType.hs#L72-74).
      expected = [
        "application/json",
        "application/vnd.pgrst.object+json;nulls=stripped",
        "application/vnd.pgrst.object+json"
      ]

      assert doc["paths"]["/rpc/varied_arguments_openapi"]["get"]["produces"] == expected
      assert doc["paths"]["/rpc/varied_arguments_openapi"]["post"]["produces"] == expected
      assert doc["paths"]["/rpc/reset_table"]["post"]["produces"] == expected
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/bier/openapi_test.exs`
Expected: FAIL — `doc["paths"]["/"]` is `nil`; the RPC ops have no `"produces"` key.

- [ ] **Step 3: Implement**

In `lib/bier/openapi.ex`:

(a) `paths/1` gains the root item (OpenAPI.hs#L370-383):

```elixir
  defp paths(input) do
    rel_paths = Map.new(input.relations, fn rel -> {"/" <> rel.name, relation_path_item(rel)} end)

    rel_paths
    |> Map.merge(function_paths(input))
    |> Map.put("/", root_path_item())
  end

  # The root introspection entry: GET-only, no parameters, produces the
  # OpenAPI media type pair (makeRootPathItem, OpenAPI.hs#L370-379).
  defp root_path_item do
    %{
      "get" => %{
        "tags" => ["Introspection"],
        "summary" => "OpenAPI description (this document)",
        "produces" => ["application/openapi+json", "application/json"],
        "responses" => %{"200" => %{"description" => "OK"}}
      }
    }
  end
```

(b) module attribute near the top (after `@default_description`), and both RPC ops in `function_path_item/1` gain it (OpenAPI.hs#L360):

```elixir
  # Every RPC operation advertises these (procOp produces, OpenAPI.hs#L360).
  @rpc_produces [
    "application/json",
    "application/vnd.pgrst.object+json;nulls=stripped",
    "application/vnd.pgrst.object+json"
  ]
```

In `function_path_item/1`, add `"produces" => @rpc_produces` to both operation maps:

```elixir
    post =
      %{
        "tags" => tags,
        "produces" => @rpc_produces,
        "parameters" => [
          rpc_body_param(fun, summary, description),
          %{"$ref" => "#/parameters/preferParams"}
        ],
        "responses" => %{"200" => %{"description" => "OK"}}
      }
      |> put_optional("summary", summary)
      |> put_optional("description", description)
```

```elixir
      get =
        %{
          "tags" => tags,
          "produces" => @rpc_produces,
          "parameters" => Enum.map(fun.in_params, &rpc_query_param/1),
          "responses" => %{"200" => %{"description" => "OK"}}
        }
        |> put_optional("summary", summary)
        |> put_optional("description", description)
```

- [ ] **Step 4: Run the unit tests, then the openapi conformance area**

Run: `mix test test/bier/openapi_test.exs`
Expected: PASS.

Run: `mix test --only area:openapi`
Expected: PASS (assertions are `body_jsonpath`-targeted; the new keys are invisible to them).

- [ ] **Step 5: Commit**

```bash
git add lib/bier/openapi.ex test/bier/openapi_test.exs
git commit -m "openapi: emit the root / path item and rpc produces lists

PostgREST v14.12 inserts a GET-only Introspection path item for / (
makeRootPathItem, OpenAPI.hs#L370-379) and stamps every RPC operation
with produces [json, vnd.pgrst.object+json;nulls=stripped,
vnd.pgrst.object+json] (OpenAPI.hs#L360). Issue #85 items 1-2.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Unconditional `schemes`/`host`/`basePath` block (server-config fallback)

Issue #85 item 3, plus removing the port-omission deviation in the proxy branch. `postgrestSpec` always receives `(scheme, host, port, basePath)` — from the proxy URI when set, otherwise `("http", configServerHost, configServerPort, "/")` — and always emits all three keys with the port appended to `host` (OpenAPI.hs#L393-414, L448-454).

**Files:**
- Modify: `lib/bier/openapi.ex` (`build/1` ~L19-60: replace `with_proxy/2` with a unified server block)
- Modify: `lib/bier/plugs/action_controller.ex` (`build_openapi_document/2` ~L208-215: thread server host/scheme/port)
- Test: `test/bier/openapi_test.exs` (proxy describe ~L764-785 + helpers ~L788-837)

**Interfaces:**
- Consumes: `Bier.Config` fields `server_host :: String.t()` and `router :: keyword()` (`[:scheme]` atom `:http | :https`, `[:port]` pos_integer) — all existing.
- Produces: `Bier.OpenAPI.build/1` input map gains required keys `:server_scheme` (atom), `:server_host` (string), `:server_port` (pos_integer). `:proxy_uri` stays optional (`input[:proxy_uri]`).

- [ ] **Step 1: Update and extend the tests**

In `test/bier/openapi_test.exs`, replace the `"build/1 proxy (openapi-server-proxy-uri)"` describe with:

```elixir
  describe "build/1 schemes/host/basePath (openapi-server-proxy-uri + server fallback)" do
    # postgrestSpec always emits schemes/host/basePath; with no proxy they
    # come from the server config ("http", server-host, port, "/") and the
    # port is always appended to host (OpenAPI.hs#L393-414, L448-454;
    # swagger2 Host ToJSON). Issue #85 item 3.
    test "absent proxy: server config seeds schemes, escaped host:port, basePath /" do
      doc = build_one_with_proxy(nil)
      assert doc["schemes"] == ["http"]
      # "!4" is a listen-anywhere value: escapeHostName maps it to 0.0.0.0
      # (Network.hs#L46-52).
      assert doc["host"] == "0.0.0.0:4040"
      assert doc["basePath"] == "/"
    end

    test "every listen-anywhere server_host form escapes to 0.0.0.0 (Network.hs#L46-52)" do
      for h <- ~w(* *4 !4 *6 !6) do
        assert build_one_with_server(h, :http, 3000)["host"] == "0.0.0.0:3000"
      end
    end

    test "a concrete server_host passes through, and :https maps the scheme" do
      doc = build_one_with_server("api.internal", :https, 8443)
      assert doc["schemes"] == ["https"]
      assert doc["host"] == "api.internal:8443"
    end

    test "proxy URI seeds schemes, host with explicit port, and basePath" do
      doc = build_one_with_proxy("https://example.com:8443/basePath")
      assert doc["schemes"] == ["https"]
      assert doc["host"] == "example.com:8443"
      assert doc["basePath"] == "/basePath"
    end

    test "scheme-default proxy ports are still appended; empty path maps to /" do
      # pickProxy fills 80/443 for portless URIs and postgrestSpec always
      # renders Host with the port (OpenAPI.hs#L414, L441-446) — the
      # previous omit-default-port behavior was a deviation.
      assert build_one_with_proxy("http://example.com")["host"] == "example.com:80"
      assert build_one_with_proxy("https://example.com")["host"] == "example.com:443"
      assert build_one_with_proxy("http://example.com")["basePath"] == "/"
    end
  end
```

And update the helpers so every builder threads the new required server keys (defaults mirror a stock instance: `server_host "!4"`, scheme `:http`, port 4040):

```elixir
  # --- helpers ---
  defp build_input(overrides) do
    Map.merge(
      %{
        relations: [],
        functions: [],
        schema_comment: nil,
        security_active?: false,
        docs_version: "v14",
        server_scheme: :http,
        server_host: "!4",
        server_port: 4040
      },
      overrides
    )
  end

  defp build_one_with_proxy(proxy_uri),
    do: Bier.OpenAPI.build(build_input(%{proxy_uri: proxy_uri}))

  defp build_one_with_server(host, scheme, port),
    do:
      Bier.OpenAPI.build(
        build_input(%{server_host: host, server_scheme: scheme, server_port: port})
      )

  defp p(name, type, variadic?, has_default?),
    do: %{name: name, type: type, variadic?: variadic?, has_default?: has_default?}

  defp p_var(name, type), do: p(name, type, true, false)

  defp build_fns(fns), do: Bier.OpenAPI.build(build_input(%{functions: fns}))

  defp build_one(rel), do: Bier.OpenAPI.build(build_input(%{relations: [rel]}))
```

(Keep `col_map/2` as is.)

Also rewrite the five inline `Bier.OpenAPI.build(%{...})` calls in the `"build/1 skeleton"` (~L181-226) and `"build/1 security (1679/1680)"` (~L228-261) describes to go through the helper, since `:server_scheme`/`:server_host`/`:server_port` are now required input keys:

- skeleton "swagger + default info + externalDocs": `doc = Bier.OpenAPI.build(build_input(%{}))`
- "schema comment seeds title/description": `doc = Bier.OpenAPI.build(build_input(%{schema_comment: "My API title\nMy API description\nthat spans\nmultiple lines"}))`
- "single-line schema comment": `doc = Bier.OpenAPI.build(build_input(%{schema_comment: "Just a title"}))`
- security "absent by default": `doc = Bier.OpenAPI.build(build_input(%{}))`
- security "present when security_active?": `doc = Bier.OpenAPI.build(build_input(%{security_active?: true}))`

(ExUnit compiles the whole file, so `build_input/1` being defined below its call sites is fine.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/bier/openapi_test.exs`
Expected: FAIL — no-proxy docs have no `host`/`schemes`; portless proxy hosts lack `:80`/`:443`.

- [ ] **Step 3: Implement the unified server block**

In `lib/bier/openapi.ex`, replace `with_proxy/2` + `base_path/1` (~L38-60) and the `build/1` pipeline. `build/1` becomes:

```elixir
  def build(input) do
    {title, desc} = info(input.schema_comment)
    {scheme, host, port, base_path} = server_block(input)

    %{
      "swagger" => "2.0",
      "info" => put_optional(%{"title" => title, "version" => "14.12"}, "description", desc),
      "externalDocs" => %{
        "url" => "https://postgrest.org/en/#{input.docs_version}/references/api.html",
        "description" => "PostgREST Documentation"
      },
      "schemes" => [scheme],
      "host" => "#{escape_host_name(host)}:#{port}",
      "basePath" => base_path,
      "paths" => paths(input),
      "definitions" => definitions(input),
      "parameters" => parameters(input)
    }
    |> with_security(input.security_active?)
  end

  # postgrestSpec always receives (scheme, host, port, basePath): from
  # openapi-server-proxy-uri when set, otherwise the server config — and the
  # port is always rendered into `host` (OpenAPI.hs#L393-414, L448-454).
  # PostgREST hardcodes "http" in the fallback (it has no native TLS); Bier
  # serves :https via Bandit, so the fallback scheme follows router[:scheme].
  defp server_block(input) do
    case input[:proxy_uri] do
      nil ->
        {to_string(input.server_scheme), input.server_host, input.server_port, "/"}

      proxy_uri ->
        # Validated at boot (Bier.Config): scheme is http/https, host present.
        # URI.parse fills the scheme-default port for portless URIs, matching
        # pickProxy's 80/443 fallback (OpenAPI.hs#L441-446).
        uri = URI.parse(proxy_uri)
        {uri.scheme, uri.host, uri.port, base_path(uri.path)}
    end
  end

  # Listen-anywhere host values render as 0.0.0.0 (escapeHostName,
  # Network.hs#L46-52); concrete hosts pass through.
  defp escape_host_name(host) when host in ["*", "*4", "!4", "*6", "!6"], do: "0.0.0.0"
  defp escape_host_name(host), do: host

  defp base_path(path) when path in [nil, ""], do: "/"
  defp base_path(path), do: path
```

In `lib/bier/plugs/action_controller.ex` `build_openapi_document/2`, extend the emitter input:

```elixir
    Bier.OpenAPI.build(%{
      relations: relations,
      functions: function_inputs(functions),
      schema_comment: cache.schema_comment,
      security_active?: config.openapi_security_active,
      proxy_uri: config.openapi_server_proxy_uri,
      server_scheme: config.router[:scheme],
      server_host: config.server_host,
      server_port: config.router[:port],
      docs_version: "v14"
    })
```

- [ ] **Step 4: Run the unit tests, the openapi area, then the full suite**

Run: `mix test test/bier/openapi_test.exs`
Expected: PASS.

Run: `mix test --only area:openapi`
Expected: PASS (no case asserts `host`/`schemes`/`basePath` values — checked; the conformance instance simply gains the keys).

Run: `mix test`
Expected: full suite PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/openapi.ex lib/bier/plugs/action_controller.ex test/bier/openapi_test.exs
git commit -m "openapi: always emit schemes/host/basePath, from server config sans proxy

postgrestSpec unconditionally renders the scheme/host/port/basePath block,
falling back to (http, server-host, port, /) when no
openapi-server-proxy-uri is set, with listen-anywhere hosts escaped to
0.0.0.0 and the port always appended — including scheme-default proxy
ports, removing our omit-default-port deviation (OpenAPI.hs#L393-454,
Network.hs#L46-52). Issue #85 item 3.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Final gates + follow-up note

**Files:**
- No source changes.

**Interfaces:**
- Consumes: completed Tasks 1–2.
- Produces: a green `mix precommit`; a reported follow-up gap.

- [ ] **Step 1: Run every CI gate**

Run: `mix precommit`
Expected: all gates PASS.

- [ ] **Step 2: Report the remaining discovered gap to the operator (do NOT create an issue without approval)**

While verifying #85 against the v14.12 source, one further uncased top-level gap surfaced: `postgrestSpec` emits document-level `produces` AND `consumes` lists of `[application/json, application/vnd.pgrst.object+json;nulls=stripped, application/vnd.pgrst.object+json, text/csv]` (OpenAPI.hs#L408-409); Bier emits neither key. Report this in the final summary as a candidate follow-up issue.

> **Amendment (operator-approved, 2026-07-16):** bundle the document-level `produces`/`consumes` fix into this branch instead of filing a follow-up. Task 2b below; executed after the PR was first opened, as an additional commit on the same PR.

---

### Task 2b (amendment): Document-level `produces`/`consumes`

`postgrestSpec` stamps the Swagger root with equal `produces` and `consumes` lists: the RPC trio plus `text/csv` (OpenAPI.hs#L408-409; `MTTextCSV` → `"text/csv"`, MediaType.hs). Uncased: no conformance case or `absent:` predicate targets either key (same grep as the header note).

**Files:**
- Modify: `lib/bier/openapi.ex` (`build/1` document map; reuse `@rpc_produces`)
- Test: `test/bier/openapi_test.exs` (`"build/1 skeleton"` describe)

- [ ] **Step 1: Write the failing test** — in the `"swagger + default info + externalDocs (1650/1654/1655)"` test, append:

```elixir
      # The document root advertises the rpc trio + text/csv on BOTH
      # produces and consumes (postgrestSpec, OpenAPI.hs#L408-409).
      expected_mimes = [
        "application/json",
        "application/vnd.pgrst.object+json;nulls=stripped",
        "application/vnd.pgrst.object+json",
        "text/csv"
      ]

      assert doc["produces"] == expected_mimes
      assert doc["consumes"] == expected_mimes
```

- [ ] **Step 2: Run to verify it fails** — `mix test test/bier/openapi_test.exs`; expected FAIL: both keys `nil`.

- [ ] **Step 3: Implement** — in `lib/bier/openapi.ex`, add below `@rpc_produces`:

```elixir
  # The document root advertises the rpc trio + csv on both produces and
  # consumes (postgrestSpec, OpenAPI.hs#L408-409).
  @doc_mimes @rpc_produces ++ ["text/csv"]
```

and in `build/1`'s document map, after `"basePath" => base_path,`:

```elixir
      "produces" => @doc_mimes,
      "consumes" => @doc_mimes,
```

- [ ] **Step 4: Run** — `mix test test/bier/openapi_test.exs` then `mix test --only area:openapi` then `mix test`; expected PASS.

- [ ] **Step 5: Commit** — message: `openapi: advertise document-level produces/consumes` with the OpenAPI.hs#L408-409 citation and the Co-Authored-By trailer.

- [ ] **Step 3: Hand off**

Use superpowers:finishing-a-development-branch. Suggested PR title: "OpenAPI root document: root path item, rpc produces, default host/schemes (#85)". The PR closes #85.
