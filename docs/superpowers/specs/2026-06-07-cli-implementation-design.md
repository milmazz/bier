# Bier CLI — standalone-runnable, drop-in PostgREST-compatible config

**Issue:** #40 ([conformance][lib] CLI implementation — 26 pending config cases)
**Date:** 2026-06-07
**Status:** Approved design (pending written-spec review)

## Context

26 conformance cases in the `config` area (`spec/conformance/cases/1705–1730`)
carry `request.kind == "cli"` and are tagged `:pending` (reason `:cli`) in
`test/conformance/conformance_test.exs` because Bier has no command-line
interface. They exercise PostgREST's CLI/config surface: flag parsing, env/file
loading, `--dump-config`/`--example` output, validation messages, and exit
codes.

PostgREST is a single standalone binary, so its CLI *is* the product's entry
point and `--dump-config` is its config-introspection surface. Bier, by
contrast, is an Elixir **library**: it is configured through `Bier.start_link/1`
keyword options inside a host application's supervision tree (`Bier.Application`
starts only `Bier.Registry`; the host starts instances). Bier has no standalone
daemon today.

### How PostgREST does it (v14.12, for reference)

- **One config record, one serializer.** `readAppConfig` parses all sources into
  a single `AppConfig`; `toText :: AppConfig -> Text` renders it back.
  `--dump-config` is "parse → `toText` → exit 0", which is why it is stable and
  reparseable. The running server, the dump, and `--example` all read the same
  record.
- **Three sources, precedence db-settings > env > file > default.**
- **CLI surface:** default action boots the server (`Run CmdRun`); flags
  `--dump-config`, `--dump-schema`, `--example`/`-e`, `--ready` (hits the admin
  server's `/ready`), `-v/--version`, plus an optional positional config-file
  path.
- **File format:** the Haskell `configurator` library (`key = value`, quoted
  strings, `app.settings.*` dotted keys, comments).
- **Aliases / coercion / validation:** `optWithAlias` tries canonical then
  deprecated key; wrong-typed values coerce to absent and fall back to default
  (never crash); validations `fail` with exact message strings.

The key insight: PostgREST's full key table is **not** technical debt because
PostgREST *implements every key in it*. For Bier, "should we model key X"
reduces to "does Bier implement feature X." This design follows the *same
pattern* as PostgREST, scaled to Bier's smaller (growing) feature set.

## Goals

1. Make Bier **runnable as a standalone service** (`docker run bier`,
   eventually) — the adoption lever PostgREST's distribution model proves out.
   A single instance, configured entirely from outside an Elixir host app.
2. Be a **config-level drop-in for PostgREST** for the keys Bier implements:
   same `PGRST_*` env vars, same kebab key names, a compatible config-file
   format, and a PostgREST-format `--dump-config`. This is the compatibility
   contract that makes "swap PostgREST for Bier" credible.
3. Provide a **testable, in-process CLI core** the conformance harness can drive
   directly, so `kind: cli` cases run fast and `async`-safe.
4. Turn green every conformance case that maps onto config Bier **actually
   implements**; give every other case a **documented, honest** pending reason.

## Non-goals (explicitly deferred)

- **Reproducing PostgREST's full key table / golden dump files.** Keys Bier does
  not implement are simply absent from the mapping. Cases 1705 (full defaults
  dump) and 1727 (`--example` template) stay deferred until every key exists.
- **DB-role-settings config source** (`db-config`, `ALTER ROLE ... SET pgrst.*`)
  — cases 1724/1725. Needs a live connection at parse time; out of scope here.
- **Unmodeled keys:** `jwt-role-claim-key` (1711), `server-unix-socket-mode`
  (1714/1715), `openapi-server-proxy-uri` (1716), `jwt-secret-is-base64` (1718),
  `app.settings.*` (1729). They become reachable only when/if Bier implements
  those features.
- **`mix release` config + Dockerfile.** Split into a tracked follow-up issue;
  mechanical and independently reviewable. This issue delivers the core, the
  escript, the standalone boot path, and the conformance wiring.
- **`--dump-schema`.** Not required by any case; out of scope.

## Architecture

```
                       argv + env(map) + optional file path
                                     │
                                     ▼
                         ┌───────────────────────┐
   conformance harness ─▶│   Bier.CLI.run/2      │◀─ escript Bier.CLI.main/1
   (in-process, async)   │  (pure, no IO/halt)   │   (System.argv/get_env/halt)
                         └───────────┬───────────┘
                                     │ %{stdout, stderr, exit}
                ┌────────────────────┼─────────────────────┐
                ▼                    ▼                      ▼
        Bier.CLI.Config      Bier.CLI.Config.dump     command dispatch
        .load(env,file,argv)  (PostgREST toText)      (--help/-v/--ready/
                │                                       --dump-config/run)
                ▼
   PostgREST dialect → Bier.Config atoms
   (kebab keys, PGRST_* env, aliases, coercion)
                │
                ▼
        Bier.Config.new!/2  ── shared validators (PostgREST-exact messages) ──┐
                │                                                              │
                ▼                            also enforced by                 │
        Bier.start_link/1 (standalone: one instance) ◀────────────────────────┘
```

The boundary translates the **PostgREST dialect** into Bier's internal
`Bier.Config` atoms, then hands off to the *existing* `Bier.start_link/1` path.
Validation lives in the shared config path so the library and the CLI reject
identically.

### Components

**`Bier.CLI` (new, `lib/bier/cli.ex`)** — the entry point and command dispatch.
- `run(argv, opts) :: %{stdout: iodata, stderr: iodata, exit: non_neg_integer}`
  — pure core. `opts` supplies `:env` (a map, default `System.get_env()` is
  *not* read here — the caller passes it) and resolves an optional positional
  config-file path from `argv`. No real IO, no `System.halt`. This is what the
  conformance harness calls.
- `main(argv)` — the escript wrapper: `run(argv, env: System.get_env())`, then
  `IO.write(stdout)`, `IO.write(:stderr, stderr)`, `System.halt(exit)`.
- Command dispatch: default → boot a standalone instance; `--dump-config`,
  `--ready`, `--version`/`-v`, `--help`/`-h`. Unknown flags → usage + nonzero.

**`Bier.CLI.Config` (new, `lib/bier/cli/config.ex`)** — the PostgREST↔Bier
config boundary.
- `load(env_map, file_path_or_nil, flag_overrides) :: {:ok, keyword} |
  {:error, message}` — reads sources, applies precedence, resolves aliases,
  coerces types, and returns a keyword list ready for `Bier.start_link/1`
  (Bier's snake_case atoms), or an error message for a fatal config problem.
- `dump(keyword_or_struct) :: iodata` — PostgREST-format serialization
  (`key = "value"` / bare ints / lowercase bools) of the loaded config, over the
  keys Bier models. Deterministic ⇒ reparse-stable.
- Owns the **mapping table** (single source of truth): canonical kebab key →
  `{bier_atom, type, default, aliases, env_var}`.

**`Bier.CLI.ConfigFile` (new, `lib/bier/cli/config_file.ex`)** — a small parser
for the config-file subset (see below). `parse(contents) :: {:ok, map} |
{:error, message}`.

**`Bier.Config` (existing, extended)** — gains custom validators that emit
PostgREST-exact messages (see Validation). These run inside `new!/2`, so
`Bier.start_link/1` enforces them too.

## Config mapping (PostgREST dialect → Bier)

Only keys Bier implements appear. Direct mappings unless noted.

| PostgREST key | `PGRST_*` env | Bier target | Notes |
|---|---|---|---|
| `db-uri` | `PGRST_DB_URI` | `hostname`,`port`,`database`,`username`,`password` | parse libpq URI into Bier's discrete fields |
| `db-schemas` (alias `db-schema`) | `PGRST_DB_SCHEMAS` | `db_schemas` | CSV → list |
| `db-anon-role` | `PGRST_DB_ANON_ROLE` | `db_anon_role` | |
| `db-extra-search-path` | `PGRST_DB_EXTRA_SEARCH_PATH` | `db_extra_search_path` | emptyable CSV |
| `db-max-rows` (alias `max-rows`) | `PGRST_DB_MAX_ROWS` | `db_max_rows` | opt-int |
| `db-tx-end` | `PGRST_DB_TX_END` | `db_tx_end` | enum |
| `db-pre-request` (alias `pre-request`) | `PGRST_DB_PRE_REQUEST` | `db_pre_request` | |
| `db-root-spec` (alias `root-spec`) | `PGRST_DB_ROOT_SPEC` | `db_root_spec` | |
| `server-port` | `PGRST_SERVER_PORT` | `router[:port]` | |
| `server-host` | `PGRST_SERVER_HOST` | Bandit bind (router) | |
| `admin-server-port` | `PGRST_ADMIN_SERVER_PORT` | `admin_server_port` | must differ from server-port |
| `jwt-secret` | `PGRST_JWT_SECRET` | `jwt_secret` | ≥ 32 chars if symmetric |
| `jwt-aud` | `PGRST_JWT_AUD` | `jwt_aud` | string or valid URI |
| `openapi-mode` | `PGRST_OPENAPI_MODE` | `openapi_mode` | enum |
| `log-level` | `PGRST_LOG_LEVEL` | `log_level` | enum |
| `server-cors-allowed-origins` | `PGRST_SERVER_CORS_ALLOWED_ORIGINS` | `server_cors_allowed_origins` | |

Keys present in the conformance cases but **not** mapped (deferred):
`db-channel`, `server-unix-socket-mode`, `jwt-role-claim-key`,
`jwt-secret-is-base64`, `openapi-server-proxy-uri`, `db-pool-*`,
`app.settings.*`.

## Sources & precedence

`flags > PGRST_* env > config file > default`.

This is PostgREST's order minus the DB-settings tier (deferred). Matches case
1720 (env overrides file). Resolution per key: take the first present source;
apply the key's coercion; on wrong type, treat as absent and fall back (case
1721). Empty string for an opt-string key = absent (case 1723); emptyable CSV
keys yield `[]` for empty (case 1728).

## Config-file format

A pragmatic subset of PostgREST's `configurator` format — enough for real
configs and the cases, not full configurator parity:

- `key = value` lines; `#` line comments; blank lines ignored.
- String values double-quoted with `\"` escapes; bare integers; bare
  `true`/`false`.
- `app.settings.*` dotted keys parsed (stored, but not yet wired — only needed
  if/when app-settings lands; for now an unknown-but-well-formed key is retained
  for the dump round-trip, never fatal).
- A **missing** config file (path given but not found) is fatal → nonzero exit
  (case 1719).

## Validation (shared, PostgREST-exact messages)

Added as custom validators in the `Bier.Config` path so `start_link/1` and the
CLI enforce identically. Each emits the exact substring the case asserts:

| Case | Rule | Message substring |
|---|---|---|
| 1708 | jwt-secret ≥ 32 chars (symmetric) | `The JWT secret must be at least 32 characters long.` |
| 1709 | jwt-aud string or valid URI | `jwt-aud should be a string or a valid URI` |
| 1710 | openapi-mode ∈ enum | `Invalid openapi-mode. Check your configuration.` |
| 1712 | log-level ∈ enum | `Invalid logging level. Check your configuration.` |
| 1713 | db-tx-end ∈ enum | `Invalid transaction termination. Check your configuration.` |
| 1717 | admin-server-port ≠ server-port | `admin-server-port cannot be the same as server-port` |

A failed validation in the CLI prints the message to **stderr** and exits
nonzero. (Within `start_link/1` it raises, as today.)

## CLI surface

- **default (no flag):** load config, validate, boot **one** standalone Bier
  instance (name `Bier`), keep the VM alive. Standalone boot only; multi-instance
  remains the embedded-library story.
- `--dump-config`: load + validate, print PostgREST-format dump to stdout, exit 0.
- `--ready`: issue a request to the admin server's `/ready`; exit 0/nonzero by
  result. (Requires `admin-server-port` set.)
- `-v` / `--version`: print version, exit 0.
- `-h` / `--help`: usage, exit 0.
- positional arg: config-file path.

## Conformance harness changes

- **`Bier.ConformanceCase`** already parses `kind: :cli`, `request.flag`, and
  `config.env` / `config.file`. Add reading of `config.file` into a temp file
  and `config.env` into a map for the CLI path (no change to the struct).
- **New `Bier.CliCase` case template** (`test/support/cli_case.ex`), parallel to
  `Bier.HttpCase`: `perform/1` writes any `config.file` to a temp path, then
  calls `Bier.CLI.run(flag_args, env: case.config.env, file: temp_path)` and
  returns `%{stdout, stderr, exit}`.
- **New assertions** in `Bier.ConformanceAssertions`: `exit_code`
  (`0` / `nonzero`), `dump_contains` (each string is a substring of stdout),
  `stderr_contains`, `dump_reparse_stable` (write stdout to a file, re-run
  `--dump-config` against it, assert byte-identical).
- **`conformance_test.exs`** dispatch: route `c.kind == :cli` to the CLI path
  instead of flunking. Replace the blanket `c.kind == :cli -> :cli` pending arm
  with a narrower predicate that defers only cases touching unmodeled keys / the
  full-table dump / db-config (reasons `:cli_parity`, `:unmodeled_key`,
  `:db_config`).

## Expected conformance disposition

Pinned during build; current best estimate:

- **Pass — validation:** 1708, 1709, 1710, 1712, 1713, 1717.
- **Pass — file support:** 1719.
- **Pass — dump (implemented keys):** likely 1706, 1720, 1721, 1722, 1723, 1728,
  1730; 1726 (reparse-stable) plausible.
- **Defer `:cli_parity`** (full table / example): 1705, 1727.
- **Defer `:unmodeled_key`:** 1707 (mixed unimplemented aliases), 1711, 1714,
  1715, 1716, 1718, 1729.
- **Defer `:db_config`:** 1724, 1725.

Any case that does not pass keeps an explicit, documented reason — no façade to
force green.

## Module layout

```
lib/bier/cli.ex              # Bier.CLI: run/2 core, main/1 escript, dispatch
lib/bier/cli/config.ex       # Bier.CLI.Config: mapping table, load/3, dump/1
lib/bier/cli/config_file.ex  # Bier.CLI.ConfigFile: parse/1
lib/bier/config.ex           # extended: shared validators
test/support/cli_case.ex     # Bier.CliCase
test/support/conformance_assertions.ex  # + cli assertions
mix.exs                      # escript: [main_module: Bier.CLI]
```

## Testing strategy

- **TDD** per the project's workflow. The conformance cases are the acceptance
  tests; drive each implemented-key case from red to green.
- **Unit tests** for `Bier.CLI.Config` (precedence, alias resolution, coercion,
  `db-uri` parsing, dump format) and `Bier.CLI.ConfigFile` (parse + error on
  missing).
- **Core is pure** ⇒ no IO capture needed in tests; assert the returned
  `%{stdout, stderr, exit}` map directly. Escript `main/1` stays a thin,
  untested-by-conformance wrapper (smoke-tested separately if cheap).
- CI gates unchanged (`mix format`, `--warnings-as-errors`, `mix docs`, etc.).

## Follow-up (separate issue)

- `mix release` config + runtime config loader + Dockerfile to realize
  `docker run bier` end-to-end.
- Implement deferred keys (role-claim-key, socket-mode, base64 secret, …) to
  retire their `:unmodeled_key` dispositions.
- DB-role-settings (`db-config`) source for 1724/1725.
