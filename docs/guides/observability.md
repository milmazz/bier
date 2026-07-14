# Observability

How to watch a running `Bier` instance: the `:telemetry` events it emits, the
`Server-Timing` header it can add to every response, the admin
liveness/readiness endpoints, connection-pool sampling, request-trace header
passthrough, and the structured diagnostics it logs for database failures.
None of this changes request handling — it is read-only instrumentation
alongside the request pipeline described in the
[API reference](api-reference.md) and configured via the options in the
[Configuration reference](configuration.md).

Every signal on this page is scoped to one named instance (a node can host
several `Bier` instances at once, each its own database, config, and Bandit
server — see `Bier`), so every event and log line below carries the
instance's `:name` so a handler or log pipeline can tell them apart. The
examples use `MyApp.Bier` as that name, matching `Bier`'s own module docs.

## Telemetry events

Bier emits `:telemetry` events and leaves aggregation to the host
application — attach `Telemetry.Metrics` definitions, a reporter (Prometheus,
StatsD, …), or a plain handler with `:telemetry.attach/4` /
`:telemetry.attach_many/4`. Nothing is exported in-process, and nothing is
computed unless something is attached.

| Event | Measurements | Metadata | Emitted |
| --- | --- | --- | --- |
| `[:bier, :request, :start]` | `system_time`, `monotonic_time` | `instance`, `method`, `route` | When a request enters the pipeline (`Bier.Plugs.Observability`) |
| `[:bier, :request, :stop]` | `duration` (native time units), `monotonic_time` | `instance`, `method`, `route`, `status`, `schema`, `relation` | When the response is sent (a `Plug.Conn.register_before_send/2` callback), so `duration` is the real request wall-clock |
| `[:bier, :schema_cache, :load, :start]` | `system_time`, `monotonic_time` | `instance`, `schemas` | Start of a schema-cache load (boot introspection or a reload) |
| `[:bier, :schema_cache, :load, :stop]` | `duration` | `instance`, `schemas`, `status` (`:ok`), `relation_count` | A load completed and its snapshot was swapped in |
| `[:bier, :schema_cache, :load, :exception]` | standard span measurements | `instance`, `schemas`, `kind`, `reason`, `stacktrace` | A load raised; the previous snapshot is left in place |
| `[:bier, :pool, :status]` | `max`, `available`, `waiting` | `instance` | A periodic gauge sample of the Postgrex pool, emitted by `Bier.PoolMonitor` |
| `[:bier, :pool, :checkout_timeout]` | `count` (always `1`) | `instance` | A request's pool checkout was dropped from the queue after timing out |

`schema` and `relation` on `[:bier, :request, :stop]` are `nil` for the root
document, `OPTIONS`, and error responses that never resolve a target.

The `[:bier, :schema_cache, :load, *]` family is a `:telemetry.span/3` around
every schema-cache load — both boot-time introspection
(`Bier.HttpServerStarter`) and `Bier.SchemaCache.reload/1` (including the
LISTEN/NOTIFY-driven reload from `Bier.SchemaCacheListener`) funnel through
`Bier.SchemaCache.load!/3`. The snapshot swap happens *inside* the span,
before `:stop` fires, so a handler synchronizing on `:stop` is guaranteed the
new snapshot is already visible.

> #### Per-phase timings are not on these events {: .info}
> `[:bier, :request, :start | :stop]` carry only the **total** request
> duration. The jwt / parse / plan / transaction / response breakdown is
> measured separately and surfaced through the `Server-Timing` response
> header — see [Server-Timing](#server-timing) below.

### Attaching a handler

```elixir
:telemetry.attach(
  "log-bier-requests",
  [:bier, :request, :stop],
  fn _event, %{duration: duration}, metadata, _config ->
    if metadata.instance == MyApp.Bier do
      duration_ms = System.convert_time_unit(duration, :native, :millisecond)

      Logger.info(
        "#{metadata.method} #{metadata.route} -> #{metadata.status} (#{duration_ms}ms)"
      )
    end
  end,
  nil
)
```

Filtering on `metadata.instance` is what scopes the handler to one instance
when several are running in the same node; `attach_many/4` is the usual
choice when one handler wants several events (e.g. both `[:bier, :pool,
:status]` and `[:bier, :pool, :checkout_timeout]` feeding one gauge/counter
reporter).

### Not yet emitted

`[:bier, :jwt_cache, …]` is not emitted: Bier verifies every JWT directly and
has no verification cache to instrument (tracked as a follow-up).

## Server-Timing

Set `server_timing_enabled: true` (env `PGRST_SERVER_TIMING_ENABLED`,
default `false`) to have every response carry a `Server-Timing` header with
the per-phase durations PostgREST reports: `jwt`, `parse`, `plan`,
`transaction`, `response`. When disabled the header is omitted entirely.

Each phase is *measured* at its real call site (`Bier.ServerTiming.measure/2`)
and accumulated per request — a phase that did no work for a given request
reports `0.000`, never a fabricated share of the total. The header format is
`<name>;dur=<milliseconds>` (three decimal places), phases comma-separated in
that fixed order:

```http
server-timing: jwt;dur=0.512, parse;dur=0.037, plan;dur=1.204, transaction;dur=3.881, response;dur=0.096
```

`OPTIONS` responses run no query planning or database transaction, so they
report only the `jwt`, `parse`, `response` subset — `plan` and `transaction`
are omitted from the header entirely, not rendered as zero:

```http
server-timing: jwt;dur=0.000, parse;dur=0.012, response;dur=0.004
```

Timing is collected per request in process-scoped state
(`Bier.ServerTiming`), reset at the top of the pipeline so a connection
reused across keep-alive requests never carries a previous request's phases.

## Health and readiness (admin server)

Set `admin_server_port` (env `PGRST_ADMIN_SERVER_PORT`, default `nil`) to run
a second Bandit listener — separate from the API router, so health paths
never collide with table names — exposing:

* `GET /live` — `200` whenever the instance's process is up (pure liveness,
  no dependency checks).
* `GET /ready` — `200` when `Bier.Health.ready?/1` holds, `503` otherwise.
  Ready means: the schema cache is populated **and** the database answers a
  trivial query (`SELECT 1`). The schema-cache check runs first and
  short-circuits, so an instance with no cache yet reports `503` without
  touching the connection pool.

Every other path on the admin listener returns `404`. `admin_server_port`
must differ from the API router's port (validated at startup):

```elixir
{Bier,
 name: MyApp.Bier,
 router: [port: 4040, scheme: :http],
 admin_server_port: 4041}
```

```http
GET /ready HTTP/1.1
Host: localhost:4041

HTTP/1.1 200 OK
```

Both endpoints return an empty body — only the status code carries the
signal, which is what most orchestrators (Kubernetes probes, load balancer
health checks) expect.

## Pool monitoring

`Bier.PoolMonitor` samples the instance's Postgrex connection pool via
`DBConnection.get_connection_metrics/1` — one sample immediately on start (so
an attached handler observes the pool without waiting a full interval), then
every 5000 ms — and emits `[:bier, :pool, :status]` with:

* `max` — the configured `pool_size`;
* `available` — connections ready for checkout (`0` while the pool is busy);
* `waiting` — callers currently queued for a checkout.

These mirror PostgREST's `pgrst_db_pool_max` / `pgrst_db_pool_available` /
`pgrst_db_pool_waiting` Prometheus gauges. A sample that finds the pool
unreachable (e.g. mid-restart) is skipped silently — no event that tick, and
the poller stays alive for the next one.

The counter half — PostgREST's `pgrst_db_pool_timeouts_total` — is
event-driven rather than polled: `Bier.Plugs.FallbackController` emits
`[:bier, :pool, :checkout_timeout]` (`count: 1`) whenever a request fails
because its checkout was dropped from the pool's queue after timing out (a
`DBConnection.ConnectionError` with reason `:queue_timeout`).

## Trace header

Set `server_trace_header` (env `PGRST_SERVER_TRACE_HEADER`, default `nil`) to
the name of an incoming request header — e.g. `X-Request-Id` — to have Bier
echo its value verbatim onto the response. An empty string or `nil` leaves
the middleware a no-op; the header is never added.

```elixir
{Bier, name: MyApp.Bier, router: [port: 4040, scheme: :http], server_trace_header: "X-Request-Id"}
```

```http
GET /beers HTTP/1.1
X-Request-Id: 4c3fa1e2-9b7e-4b2a-9c3e-1a2b3c4d5e6f

HTTP/1.1 200 OK
x-request-id: 4c3fa1e2-9b7e-4b2a-9c3e-1a2b3c4d5e6f
```

This is a passthrough only — Bier does not generate a request ID when the
header is absent, and does not thread the value into telemetry metadata or
logs on its own.

## Error logging and the error envelope

`Bier.ErrorLogger` logs two database-related failure classes as structured
JSON diagnostics, mirroring PostgREST's stderr behavior:

* **PGRST001** — `"Database client error. Retrying the connection."` — the
  database connection is lost (logged from `Bier.Plugs.FallbackController`
  whenever a request fails on a `Postgrex.Error` with no SQLSTATE, or on a
  `DBConnection.ConnectionError`; the pool reconnects on its own).
* **PGRST002** — `"Could not query the database for the schema cache.
  Retrying."` — schema-cache introspection failed, on boot or on reload
  (logged from `Bier.SchemaCache.load!/3`, which then re-raises so the
  caller's own failure handling still runs).

Each is a single `Logger.error/2` call whose *message* is the JSON envelope
`{code, message, details, hint}` — `details` is the underlying exception
message (or `inspect/1` of the raw reason) — carrying `bier_instance` and
`bier_error_code` as structured metadata for log pipelines. The message is
built lazily, so nothing is encoded when the `:error` level is disabled. To
reproduce PostgREST's exact behavior (one JSON line on stderr), point the
default logger handler at standard error in the host application:

```elixir
config :logger, :default_handler, config: [type: :standard_error]
```

This diagnostic log is distinct from the HTTP response Bier sends back: a
lost connection has no SQLSTATE to map, so `Bier.Plugs.FallbackController`
renders it as a generic `"PGRST"`-coded `500`, not `"PGRST001"` — the
specific code is only in the log line. Every error response the fallback
controller renders (whatever its code) carries the same
`{code, message, details, hint}` JSON body plus a `Proxy-Status` response
header naming that code, mirroring PostgREST's `proxyStatusHeader`:

```http
HTTP/1.1 500 Internal Server Error
content-type: application/json; charset=utf-8
proxy-status: PostgREST; error=PGRST

{"code":"PGRST","message":"...","details":null,"hint":null}
```

See the [API reference](api-reference.md) for the full table of `PGRST*`
codes and their HTTP statuses.
