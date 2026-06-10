# Bier CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Bier a standalone, drop-in PostgREST-compatible command-line interface (config from `PGRST_*` env, kebab-case config file, and flags; `--dump-config`; validation) so the `kind: cli` conformance cases that map onto config Bier actually implements turn green, and Bier can run as a standalone service.

**Architecture:** A pure, testable core `Bier.CLI.run/2` (no IO, no `System.halt`) translates the PostgREST config dialect into Bier's internal `Bier.Config` atoms via `Bier.CLI.Config`, validating with the same checks `Bier.start_link/1` uses. A thin escript `Bier.CLI.main/1` wraps the core with real IO/exit. The conformance harness calls the core in-process.

**Tech Stack:** Elixir, NimbleOptions (existing schema), ExUnit, YamlElixir (existing, conformance cases). No new runtime deps.

**Scope notes (deliberate, per approved design doc `docs/superpowers/specs/2026-06-07-cli-implementation-design.md`):**
- **In:** `Bier.CLI.run/2` core, `Bier.CLI.Config` (mapping/load/dump), `Bier.CLI.ConfigFile` parser, shared validators, escript wrapper, conformance CLI harness path.
- **Deferred to a follow-up issue:** `mix release` + Dockerfile; `--ready` (client command against a running daemon — no conformance case, best smoke-tested with the release); `--example` (case 1727, `:cli_parity`); `db-config` DB-settings source (1724/1725); unmodeled keys (1711/1714/1715/1716/1718/1729).

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/bier/config.ex` (modify) | Add shared value validators `validate_jwt_secret/1`, `validate_jwt_aud/1`; call them from `new!/2`. |
| `lib/bier/cli/config_file.ex` (create) | `Bier.CLI.ConfigFile.parse/1` — parse the `key = value` config-file subset. |
| `lib/bier/cli/config.ex` (create) | `Bier.CLI.Config` — the PostgREST↔Bier mapping table, `load/3`, `dump/1`, `to_start_opts/1`, coercion helpers. |
| `lib/bier/cli.ex` (create) | `Bier.CLI` — `run/2` core + dispatch, `main/1` escript wrapper. |
| `mix.exs` (modify) | `escript: [main_module: Bier.CLI, app: nil]`. |
| `test/support/cli_case.ex` (create) | `Bier.CliCase.perform/1` — drive a `kind: cli` case through `Bier.CLI.run/2`. |
| `test/support/conformance_assertions.ex` (modify) | Add `exit_code`, `dump_contains`, `stderr_contains`, `dump_reparse_stable` clauses. |
| `test/conformance/conformance_test.exs` (modify) | Dispatch `kind: cli` cases to the CLI path; defer only by explicit ID list. |
| `test/bier/config_test.exs` (create) | Unit tests for the shared validators. |
| `test/bier/cli/config_file_test.exs` (create) | Unit tests for the file parser. |
| `test/bier/cli/config_test.exs` (create) | Unit tests for mapping/load/dump/coercion. |
| `test/bier/cli_test.exs` (create) | Unit tests for `run/2` dispatch. |

---

## Task 1: Shared value validators in `Bier.Config`

Adds the two semantic validators the library and CLI share: JWT secret minimum length (case 1708) and JWT audience URI (case 1709). `admin-server-port` (1717) is already validated in `new!/2`.

**Files:**
- Modify: `lib/bier/config.ex`
- Test: `test/bier/config_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/bier/config_test.exs`:

```elixir
defmodule Bier.ConfigTest do
  use ExUnit.Case, async: true

  describe "validate_jwt_secret/1" do
    test "nil and >= 32 chars are ok" do
      assert Bier.Config.validate_jwt_secret(nil) == :ok
      assert Bier.Config.validate_jwt_secret(String.duplicate("a", 32)) == :ok
    end

    test "shorter than 32 chars is rejected with PostgREST's message" do
      assert Bier.Config.validate_jwt_secret("short_secret") ==
               {:error, "The JWT secret must be at least 32 characters long."}
    end
  end

  describe "validate_jwt_aud/1" do
    test "nil and a plain string are ok" do
      assert Bier.Config.validate_jwt_aud(nil) == :ok
      assert Bier.Config.validate_jwt_aud("my-audience") == :ok
    end

    test "a value containing ':' must be a valid URI" do
      assert Bier.Config.validate_jwt_aud("https://example.com/aud") == :ok

      assert Bier.Config.validate_jwt_aud("foo://%%$$^^.com") ==
               {:error, "jwt-aud should be a string or a valid URI"}
    end
  end

  describe "new!/2 enforces the validators" do
    test "a too-short jwt_secret raises" do
      assert_raise ArgumentError, ~r/JWT secret must be at least 32/, fn ->
        Bier.Config.new!([jwt_secret: "short_secret"], Bier.schema())
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/config_test.exs`
Expected: FAIL — `function Bier.Config.validate_jwt_secret/1 is undefined`.

- [ ] **Step 3: Implement the validators and wire them into `new!/2`**

In `lib/bier/config.ex`, add the public validators and call them from `new!/2`. Replace the existing `new!/2` body so it runs the new checks alongside `validate_admin_server_port!/1`:

```elixir
  @spec new!(Keyword.t(), Keyword.t()) :: t() | no_return()
  def new!(opts, schema) do
    conf = NimbleOptions.validate!(opts, schema)

    validate_admin_server_port!(conf)
    raise_if_error!(validate_jwt_secret(conf[:jwt_secret]))
    raise_if_error!(validate_jwt_aud(conf[:jwt_aud]))

    struct!(__MODULE__, conf)
  end

  @doc """
  A symmetric (text) JWT secret must be at least 32 characters long. `nil`
  (no secret configured) is allowed. Mirrors PostgREST conformance case 1708.
  """
  @spec validate_jwt_secret(String.t() | nil) :: :ok | {:error, String.t()}
  def validate_jwt_secret(nil), do: :ok

  def validate_jwt_secret(secret) when is_binary(secret) do
    if String.length(secret) >= 32 do
      :ok
    else
      {:error, "The JWT secret must be at least 32 characters long."}
    end
  end

  @doc """
  `jwt-aud` may be any plain string, but a value containing ':' must parse as a
  valid absolute URI (scheme + host). Mirrors PostgREST conformance case 1709.
  """
  @spec validate_jwt_aud(String.t() | nil) :: :ok | {:error, String.t()}
  def validate_jwt_aud(nil), do: :ok

  def validate_jwt_aud(aud) when is_binary(aud) do
    cond do
      not String.contains?(aud, ":") ->
        :ok

      valid_uri?(aud) ->
        :ok

      true ->
        {:error, "jwt-aud should be a string or a valid URI"}
    end
  end

  defp valid_uri?(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host}}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp raise_if_error!(:ok), do: :ok
  defp raise_if_error!({:error, message}), do: raise(ArgumentError, message)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/config_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/bier/config.ex test/bier/config_test.exs
git commit -m "feat(#40): shared jwt-secret/jwt-aud validators in Bier.Config"
```

---

## Task 2: Config-file parser `Bier.CLI.ConfigFile`

Parses the PostgREST-compatible `key = value` subset into a `%{kebab_key => raw_value}` map. A missing file is fatal (case 1719).

**Files:**
- Create: `lib/bier/cli/config_file.ex`
- Test: `test/bier/cli/config_file_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/bier/cli/config_file_test.exs`:

```elixir
defmodule Bier.CLI.ConfigFileTest do
  use ExUnit.Case, async: true

  alias Bier.CLI.ConfigFile

  test "parses quoted strings, bare ints and bools, ignores comments/blanks" do
    contents = """
    # a comment
    db-schemas = "api,public"

    server-port = 3000
    jwt-secret-is-base64 = true
    """

    assert ConfigFile.parse(contents) ==
             {:ok,
              %{
                "db-schemas" => "api,public",
                "server-port" => 3000,
                "jwt-secret-is-base64" => true
              }}
  end

  test "unquotes escaped quotes inside string values" do
    assert ConfigFile.parse(~S(role-claim-key = ".\"role\"")) ==
             {:ok, %{"role-claim-key" => ~S(."role")}}
  end

  test "read/1 errors on a missing file" do
    assert {:error, message} = ConfigFile.read("does_not_exist.conf")
    assert message =~ "does_not_exist.conf"
  end

  test "read/1 parses an existing file" do
    path = Path.join(System.tmp_dir!(), "bier_cfg_#{System.unique_integer([:positive])}.conf")
    File.write!(path, "log-level = \"info\"\n")
    on_exit(fn -> File.rm(path) end)

    assert ConfigFile.read(path) == {:ok, %{"log-level" => "info"}}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/cli/config_file_test.exs`
Expected: FAIL — `module Bier.CLI.ConfigFile is not available`.

- [ ] **Step 3: Implement the parser**

Create `lib/bier/cli/config_file.ex`:

```elixir
defmodule Bier.CLI.ConfigFile do
  @moduledoc """
  Parses the PostgREST-compatible config-file subset into a
  `%{kebab_key => raw_value}` map: `key = value` lines, `#` comments, blank
  lines, double-quoted strings (with `\\"` escapes), bare integers, and bare
  `true`/`false`. Raw values are returned untyped; `Bier.CLI.Config` coerces
  them per the target key.
  """

  @doc "Read and parse a config file. A missing file is a fatal error."
  @spec read(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def read(path) do
    case File.read(path) do
      {:ok, contents} -> parse(contents)
      {:error, reason} -> {:error, "could not read config file #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Parse config-file contents."
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(contents) do
    contents
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case parse_line(line) do
        {:ok, {key, value}} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_line(line) do
    case String.split(line, "=", parts: 2) do
      [raw_key, raw_value] ->
        {:ok, {String.trim(raw_key), parse_value(String.trim(raw_value))}}

      _ ->
        {:error, "malformed config line: #{inspect(line)}"}
    end
  end

  defp parse_value(<<?", _::binary>> = quoted) do
    quoted
    |> String.trim("\"")
    |> String.replace(~S(\"), ~S("))
  end

  defp parse_value("true"), do: true
  defp parse_value("false"), do: false

  defp parse_value(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/cli/config_file_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/bier/cli/config_file.ex test/bier/cli/config_file_test.exs
git commit -m "feat(#40): Bier.CLI.ConfigFile key=value parser"
```

---

## Task 3: Mapping table + coercion in `Bier.CLI.Config`

Defines the single source of truth: which PostgREST keys Bier implements, their `PGRST_*` env names, aliases, types, and PostgREST defaults — plus the per-type coercion that turns raw strings into typed values and produces PostgREST-exact enum error messages (cases 1710/1712/1713).

**Files:**
- Create: `lib/bier/cli/config.ex`
- Test: `test/bier/cli/config_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/bier/cli/config_test.exs`:

```elixir
defmodule Bier.CLI.ConfigTest do
  use ExUnit.Case, async: true

  alias Bier.CLI.Config

  describe "coerce/2" do
    test ":csv splits on commas" do
      assert Config.coerce(:csv, "multi,tenant,setup") == {:ok, ["multi", "tenant", "setup"]}
    end

    test ":csv_emptyable yields [] for empty string" do
      assert Config.coerce(:csv_emptyable, "") == {:ok, []}
    end

    test ":opt_int parses ints, treats wrong type as absent" do
      assert Config.coerce(:opt_int, "1000") == {:ok, 1000}
      assert Config.coerce(:opt_int, true) == {:ok, :unset}
      assert Config.coerce(:opt_int, "") == {:ok, :unset}
    end

    test ":opt_string treats empty string as absent" do
      assert Config.coerce(:opt_string, "") == {:ok, :unset}
      assert Config.coerce(:opt_string, "x") == {:ok, "x"}
    end

    test "log-level enum maps known values, rejects unknown with PostgREST message" do
      assert Config.coerce({:enum_atom, :log_level}, "info") == {:ok, :info}

      assert Config.coerce({:enum_atom, :log_level}, "never") ==
               {:error, "Invalid logging level. Check your configuration."}
    end

    test "db-tx-end enum rejects unknown with PostgREST message" do
      assert Config.coerce({:enum_atom, :db_tx_end}, "commit-allow-override") ==
               {:ok, :"commit-allow-override"}

      assert Config.coerce({:enum_atom, :db_tx_end}, "random") ==
               {:error, "Invalid transaction termination. Check your configuration."}
    end

    test "openapi-mode enum stays a string, rejects unknown with PostgREST message" do
      assert Config.coerce({:enum_str, :openapi_mode}, "ignore-privileges") ==
               {:ok, "ignore-privileges"}

      assert Config.coerce({:enum_str, :openapi_mode}, "follow-") ==
               {:error, "Invalid openapi-mode. Check your configuration."}
    end
  end

  describe "spec/0" do
    test "exposes db-schemas with its alias and env var" do
      entry = Enum.find(Config.spec(), &(&1.key == "db-schemas"))
      assert entry.env == "PGRST_DB_SCHEMAS"
      assert "db-schema" in entry.aliases
      assert entry.kind == :csv
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/cli/config_test.exs`
Expected: FAIL — `module Bier.CLI.Config is not available`.

- [ ] **Step 3: Implement the spec table and coercion**

Create `lib/bier/cli/config.ex`:

```elixir
defmodule Bier.CLI.Config do
  @moduledoc """
  The PostgREST config dialect ↔ Bier boundary.

  `spec/0` is the single source of truth: one entry per PostgREST config key
  that Bier implements, carrying its `PGRST_*` env var, deprecated aliases,
  value type, and PostgREST default (used for `--dump-config`). Keys Bier does
  not implement are intentionally absent — their conformance cases stay
  deferred.
  """

  alias Bier.CLI.ConfigFile

  # kind:
  #   :string | :opt_string | :int | :opt_int | :bool
  #   :csv | :csv_emptyable
  #   {:enum_atom, name} | {:enum_str, name}
  # default: the PostgREST default, rendered by dump/1 when unset.
  @spec [
    %{key: "db-uri", env: "PGRST_DB_URI", kind: :string, default: "postgresql://", aliases: []},
    %{key: "db-schemas", env: "PGRST_DB_SCHEMAS", kind: :csv, default: ["public"], aliases: ["db-schema"]},
    %{key: "db-anon-role", env: "PGRST_DB_ANON_ROLE", kind: :opt_string, default: :unset, aliases: []},
    %{key: "db-extra-search-path", env: "PGRST_DB_EXTRA_SEARCH_PATH", kind: :csv_emptyable, default: ["public"], aliases: []},
    %{key: "db-max-rows", env: "PGRST_DB_MAX_ROWS", kind: :opt_int, default: :unset, aliases: ["max-rows"]},
    %{key: "db-tx-end", env: "PGRST_DB_TX_END", kind: {:enum_atom, :db_tx_end}, default: :commit, aliases: []},
    %{key: "db-pre-request", env: "PGRST_DB_PRE_REQUEST", kind: :opt_string, default: :unset, aliases: ["pre-request"]},
    %{key: "db-root-spec", env: "PGRST_DB_ROOT_SPEC", kind: :opt_string, default: :unset, aliases: ["root-spec"]},
    %{key: "server-port", env: "PGRST_SERVER_PORT", kind: :int, default: 3000, aliases: []},
    %{key: "admin-server-port", env: "PGRST_ADMIN_SERVER_PORT", kind: :opt_int, default: :unset, aliases: []},
    %{key: "jwt-secret", env: "PGRST_JWT_SECRET", kind: :opt_string, default: :unset, aliases: []},
    %{key: "jwt-aud", env: "PGRST_JWT_AUD", kind: :opt_string, default: :unset, aliases: []},
    %{key: "openapi-mode", env: "PGRST_OPENAPI_MODE", kind: {:enum_str, :openapi_mode}, default: "follow-privileges", aliases: []},
    %{key: "log-level", env: "PGRST_LOG_LEVEL", kind: {:enum_atom, :log_level}, default: :error, aliases: []},
    %{key: "server-cors-allowed-origins", env: "PGRST_SERVER_CORS_ALLOWED_ORIGINS", kind: :opt_string, default: :unset, aliases: []}
  ]

  @enum_atoms %{
    log_level: %{
      values: %{"crit" => :crit, "error" => :error, "warn" => :warn, "info" => :info, "debug" => :debug},
      message: "Invalid logging level. Check your configuration."
    },
    db_tx_end: %{
      values: %{
        "commit" => :commit,
        "commit-allow-override" => :"commit-allow-override",
        "rollback" => :rollback,
        "rollback-allow-override" => :"rollback-allow-override"
      },
      message: "Invalid transaction termination. Check your configuration."
    }
  }

  @enum_strs %{
    openapi_mode: %{
      values: ["follow-privileges", "ignore-privileges", "disabled"],
      message: "Invalid openapi-mode. Check your configuration."
    }
  }

  @doc "The config key spec table (one entry per implemented PostgREST key)."
  @spec spec() :: [map()]
  def spec, do: @spec

  @doc """
  Coerce a raw value (string from env/file, or already-typed from the file
  parser) to the typed value for `kind`. `:unset` marks an absent optional
  value (falls back to default). Enum mismatches return PostgREST's message.
  """
  @spec coerce(term(), term()) :: {:ok, term()} | {:error, String.t()}
  def coerce(:string, v), do: {:ok, to_string(v)}

  def coerce(:opt_string, v) do
    case to_string(v) do
      "" -> {:ok, :unset}
      s -> {:ok, s}
    end
  end

  def coerce(:int, v) do
    case parse_int(v) do
      {:ok, int} -> {:ok, int}
      :error -> {:ok, :unset}
    end
  end

  def coerce(:opt_int, v) do
    case parse_int(v) do
      {:ok, int} -> {:ok, int}
      :error -> {:ok, :unset}
    end
  end

  def coerce(:bool, v), do: {:ok, v in [true, "true", "1", 1]}

  def coerce(:csv, v), do: {:ok, split_csv(to_string(v))}

  def coerce(:csv_emptyable, v) do
    case to_string(v) do
      "" -> {:ok, []}
      s -> {:ok, split_csv(s)}
    end
  end

  def coerce({:enum_atom, name}, v) do
    %{values: values, message: message} = Map.fetch!(@enum_atoms, name)

    case Map.fetch(values, to_string(v)) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, message}
    end
  end

  def coerce({:enum_str, name}, v) do
    %{values: values, message: message} = Map.fetch!(@enum_strs, name)
    s = to_string(v)
    if s in values, do: {:ok, s}, else: {:error, message}
  end

  defp parse_int(v) when is_integer(v), do: {:ok, v}

  defp parse_int(v) do
    case Integer.parse(to_string(v)) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp split_csv(s) do
    s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/cli/config_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/cli/config.ex test/bier/cli/config_test.exs
git commit -m "feat(#40): Bier.CLI.Config mapping table + value coercion"
```

---

## Task 4: `Bier.CLI.Config.load/3` — sources, precedence, aliases, validation

Resolves each spec key from `flags > PGRST_* env > config file > default`, applies aliases, coerces, and runs the shared semantic validators. Returns a resolved `%{kebab_key => typed_value}` map or `{:error, message}`.

**Files:**
- Modify: `lib/bier/cli/config.ex`
- Test: `test/bier/cli/config_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/bier/cli/config_test.exs` (inside the module):

```elixir
  describe "load/3" do
    test "reads from environment only" do
      env = %{"PGRST_DB_SCHEMAS" => "multi,tenant,setup", "PGRST_DB_MAX_ROWS" => "1000", "PGRST_LOG_LEVEL" => "info"}
      assert {:ok, resolved} = Config.load(env, nil, [])
      assert resolved["db-schemas"] == ["multi", "tenant", "setup"]
      assert resolved["db-max-rows"] == 1000
      assert resolved["log-level"] == :info
    end

    test "env overrides file (case 1720)" do
      file = %{"db-max-rows" => 100, "log-level" => "warn"}
      env = %{"PGRST_DB_MAX_ROWS" => "999", "PGRST_LOG_LEVEL" => "debug"}
      assert {:ok, resolved} = Config.load(env, file, [])
      assert resolved["db-max-rows"] == 999
      assert resolved["log-level"] == :debug
    end

    test "resolves the db-schema alias (case 1730)" do
      assert {:ok, resolved} = Config.load(%{}, %{"db-schema" => "aliased_schema"}, [])
      assert resolved["db-schemas"] == ["aliased_schema"]
    end

    test "wrong type for an int key falls back to default/unset (case 1721)" do
      assert {:ok, resolved} = Config.load(%{}, %{"db-max-rows" => true}, [])
      assert resolved["db-max-rows"] == :unset
    end

    test "empty log-level falls back to default error (case 1723)" do
      assert {:ok, resolved} = Config.load(%{"PGRST_LOG_LEVEL" => ""}, nil, [])
      assert resolved["log-level"] == :error
    end

    test "a too-short jwt-secret is fatal (case 1708)" do
      assert Config.load(%{"PGRST_JWT_SECRET" => "short_secret"}, nil, []) ==
               {:error, "The JWT secret must be at least 32 characters long."}
    end

    test "an unknown log-level is fatal (case 1712)" do
      assert Config.load(%{"PGRST_LOG_LEVEL" => "never"}, nil, []) ==
               {:error, "Invalid logging level. Check your configuration."}
    end
  end
```

Note: an empty `PGRST_LOG_LEVEL` (case 1723) is an empty optional string → absent → the key's default (`:error`); coercion of an *unset* source is skipped (see implementation). The enum coercion only runs on a present, non-empty value.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/cli/config_test.exs`
Expected: FAIL — `function Bier.CLI.Config.load/3 is undefined`.

- [ ] **Step 3: Implement `load/3`**

Add to `lib/bier/cli/config.ex`. The resolver treats an empty string / missing source as "absent" *before* coercion, so an empty value falls back to the default rather than hitting enum validation:

```elixir
  @doc """
  Resolve every spec key from flags > env > file > default, applying aliases and
  coercion, then run the shared semantic validators. Returns the resolved
  `%{kebab_key => typed_value}` map, or `{:error, message}` on a fatal problem.

  `env` is a `%{"PGRST_*" => string}` map (the caller supplies it — the core
  never reads `System.get_env/0`). `file` is `nil` or a `%{kebab_key => raw}`
  map (from `Bier.CLI.ConfigFile`). `flags` is a `%{kebab_key => raw}` map of
  command-line overrides.
  """
  @spec load(map(), map() | nil, map()) :: {:ok, map()} | {:error, String.t()}
  def load(env, file, flags) do
    file = file || %{}

    Enum.reduce_while(@spec, {:ok, %{}}, fn entry, {:ok, acc} ->
      case resolve(entry, env, file, flags) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, entry.key, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> validate()
  end

  defp resolve(entry, env, file, flags) do
    case raw_source(entry, env, file, flags) do
      :absent -> {:ok, entry.default}
      {:present, raw} -> coerce(entry.kind, raw)
    end
  end

  # Precedence: flags > env > file. Aliases are consulted for file keys only
  # (PostgREST aliases are file/env spellings; flags use canonical keys).
  defp raw_source(entry, env, file, flags) do
    cond do
      present?(Map.get(flags, entry.key)) -> {:present, Map.fetch!(flags, entry.key)}
      present?(Map.get(env, entry.env)) -> {:present, Map.fetch!(env, entry.env)}
      true -> file_source(entry, file)
    end
  end

  defp file_source(entry, file) do
    keys = [entry.key | entry.aliases]

    case Enum.find(keys, fn k -> present?(Map.get(file, k)) end) do
      nil -> :absent
      key -> {:present, Map.fetch!(file, key)}
    end
  end

  # An empty string is "absent" so it falls back to the key's default; nil/missing
  # is absent; any other value (including 0/false/integers) is present.
  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp validate({:error, _} = err), do: err

  defp validate({:ok, resolved}) do
    with :ok <- run_validator(resolved, "jwt-secret", &Bier.Config.validate_jwt_secret/1),
         :ok <- run_validator(resolved, "jwt-aud", &Bier.Config.validate_jwt_aud/1),
         :ok <- validate_admin_port(resolved) do
      {:ok, resolved}
    end
  end

  defp run_validator(resolved, key, fun) do
    case Map.get(resolved, key) do
      :unset -> :ok
      value -> fun.(value)
    end
  end

  # admin-server-port must differ from server-port (case 1717). server-port has a
  # default, so it is always present; admin-server-port may be :unset.
  defp validate_admin_port(resolved) do
    case {Map.get(resolved, "admin-server-port"), Map.get(resolved, "server-port")} do
      {port, port} when is_integer(port) -> {:error, "admin-server-port cannot be the same as server-port"}
      _ -> :ok
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/cli/config_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/cli/config.ex test/bier/cli/config_test.exs
git commit -m "feat(#40): Bier.CLI.Config.load/3 precedence, aliases, validation"
```

---

## Task 5: `Bier.CLI.Config.dump/1` — PostgREST-format serialization

Renders a resolved config map to PostgREST `--dump-config` text: one sorted `key = value` line per spec key. Strings quoted, ints bare, lists comma-joined+quoted, `:unset`/atoms rendered PostgREST-style. Deterministic ⇒ reparse-stable (case 1726).

**Files:**
- Modify: `lib/bier/cli/config.ex`
- Test: `test/bier/cli/config_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/bier/cli/config_test.exs`:

```elixir
  describe "dump/1" do
    test "renders strings, ints, lists, atoms and unset values PostgREST-style" do
      {:ok, resolved} =
        Config.load(%{"PGRST_DB_SCHEMAS" => "multi,tenant,setup", "PGRST_DB_MAX_ROWS" => "1000", "PGRST_LOG_LEVEL" => "info"}, nil, [])

      dump = Config.dump(resolved) |> IO.iodata_to_binary()

      assert dump =~ ~s(db-schemas = "multi,tenant,setup")
      assert dump =~ ~s(db-max-rows = 1000)
      assert dump =~ ~s(log-level = "info")
      # unset optional renders as empty string
      assert dump =~ ~s(db-anon-role = "")
      assert dump =~ ~s(db-max-rows = 1000)
    end

    test "an unset db-max-rows renders as empty string (case 1721)" do
      {:ok, resolved} = Config.load(%{}, %{"db-max-rows" => true}, [])
      dump = Config.dump(resolved) |> IO.iodata_to_binary()
      assert dump =~ ~s(db-max-rows = "")
    end

    test "db-tx-end round-trips its value (case 1722)" do
      {:ok, resolved} = Config.load(%{"PGRST_DB_TX_END" => "commit-allow-override"}, nil, [])
      dump = Config.dump(resolved) |> IO.iodata_to_binary()
      assert dump =~ ~s(db-tx-end = "commit-allow-override")
    end

    test "db-extra-search-path renders empty list as empty string (case 1728)" do
      {:ok, resolved} = Config.load(%{"PGRST_DB_EXTRA_SEARCH_PATH" => ""}, nil, [])
      dump = Config.dump(resolved) |> IO.iodata_to_binary()
      assert dump =~ ~s(db-extra-search-path = "")
    end

    test "dump output is reparse-stable" do
      {:ok, resolved} = Config.load(%{"PGRST_DB_MAX_ROWS" => "1000", "PGRST_SERVER_PORT" => "80", "PGRST_LOG_LEVEL" => "info"}, nil, [])
      dump1 = Config.dump(resolved) |> IO.iodata_to_binary()

      {:ok, file} = Bier.CLI.ConfigFile.parse(dump1)
      {:ok, resolved2} = Config.load(%{}, file, [])
      dump2 = Config.dump(resolved2) |> IO.iodata_to_binary()

      assert dump1 == dump2
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/cli/config_test.exs`
Expected: FAIL — `function Bier.CLI.Config.dump/1 is undefined`.

- [ ] **Step 3: Implement `dump/1`**

Add to `lib/bier/cli/config.ex`:

```elixir
  @doc """
  Render a resolved config map as PostgREST `--dump-config` text: one
  `key = value` line per spec key, sorted by key for determinism (so the output
  is reparse-stable).
  """
  @spec dump(map()) :: iodata()
  def dump(resolved) do
    @spec
    |> Enum.map(& &1.key)
    |> Enum.sort()
    |> Enum.map(fn key -> [key, " = ", render(Map.fetch!(resolved, key)), "\n"] end)
  end

  defp render(:unset), do: ~s("")
  defp render(value) when is_integer(value), do: Integer.to_string(value)
  defp render(true), do: "true"
  defp render(false), do: "false"
  defp render(value) when is_list(value), do: quote_string(Enum.join(value, ","))
  defp render(value) when is_atom(value), do: quote_string(Atom.to_string(value))
  defp render(value) when is_binary(value), do: quote_string(value)

  defp quote_string(s), do: [?", String.replace(s, ~S("), ~S(\")), ?"]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/cli/config_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/cli/config.ex test/bier/cli/config_test.exs
git commit -m "feat(#40): Bier.CLI.Config.dump/1 PostgREST-format output"
```

---

## Task 6: `Bier.CLI.run/2` — argument parsing and dispatch

The pure core. Parses argv into `{command, flags, file_path}`, calls `Config.load/3`, and returns `%{stdout, stderr, exit}` for terminal commands (`--dump-config`, `--version`, `--help`, validation errors, missing file). The default (no flag) command returns `{:boot, resolved}` for the escript to act on.

**Files:**
- Create: `lib/bier/cli.ex`
- Test: `test/bier/cli_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/bier/cli_test.exs`:

```elixir
defmodule Bier.CLITest do
  use ExUnit.Case, async: true

  alias Bier.CLI

  test "--dump-config prints config and exits 0" do
    result = CLI.run(["--dump-config"], env: %{"PGRST_LOG_LEVEL" => "info"})
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ ~s(log-level = "info")
    assert IO.iodata_to_binary(result.stderr) == ""
  end

  test "--dump-config with an invalid value prints the message to stderr, nonzero exit" do
    result = CLI.run(["--dump-config"], env: %{"PGRST_JWT_SECRET" => "short_secret"})
    assert result.exit != 0
    assert IO.iodata_to_binary(result.stderr) =~ "The JWT secret must be at least 32 characters long."
    assert IO.iodata_to_binary(result.stdout) == ""
  end

  test "a missing config file is fatal" do
    result = CLI.run(["does_not_exist.conf", "--dump-config"], env: %{})
    assert result.exit != 0
    assert IO.iodata_to_binary(result.stderr) =~ "does_not_exist.conf"
  end

  test "--version prints the version and exits 0" do
    result = CLI.run(["--version"], env: %{})
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ "bier"
  end

  test "--help prints usage and exits 0" do
    result = CLI.run(["--help"], env: %{})
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ "Usage"
  end

  test "no flag returns a boot directive" do
    assert {:boot, resolved} = CLI.run([], env: %{"PGRST_LOG_LEVEL" => "info"})
    assert resolved["log-level"] == :info
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/cli_test.exs`
Expected: FAIL — `module Bier.CLI is not available`.

- [ ] **Step 3: Implement `run/2`**

Create `lib/bier/cli.ex`:

```elixir
defmodule Bier.CLI do
  @moduledoc """
  Command-line interface for running Bier as a standalone, drop-in
  PostgREST-compatible service.

  `run/2` is the pure core: it takes argv plus an explicit environment and
  returns `%{stdout, stderr, exit}` for terminal commands, or `{:boot,
  resolved}` for the default run-the-server action. It performs no IO and never
  halts — the conformance suite drives it directly. `main/1` is the escript
  wrapper that supplies real IO and `System.halt/1`.
  """

  alias Bier.CLI.{Config, ConfigFile}

  @type result :: %{stdout: iodata(), stderr: iodata(), exit: non_neg_integer()}

  @doc "Run the CLI core. `opts[:env]` is a `%{\"PGRST_*\" => string}` map."
  @spec run([String.t()], keyword()) :: result() | {:boot, map()}
  def run(argv, opts \\ []) do
    env = Keyword.get(opts, :env, %{})
    {command, file_path} = parse_argv(argv)

    with {:ok, file} <- read_file(file_path),
         {:ok, resolved} <- Config.load(env, file, %{}) do
      dispatch(command, resolved)
    else
      {:error, message} -> error(message)
    end
  end

  defp dispatch(:version, _resolved), do: ok(version_line())
  defp dispatch(:help, _resolved), do: ok(usage())
  defp dispatch(:dump_config, resolved), do: ok(Config.dump(resolved))
  defp dispatch(:run, resolved), do: {:boot, resolved}

  # The optional positional config-file path is any argv element not starting
  # with "-". Recognized flags select the command; default command is :run.
  defp parse_argv(argv) do
    file_path = Enum.find(argv, fn arg -> not String.starts_with?(arg, "-") end)
    command = Enum.find_value(argv, :run, &flag_command/1)
    {command, file_path}
  end

  defp flag_command("--dump-config"), do: :dump_config
  defp flag_command("--version"), do: :version
  defp flag_command("-v"), do: :version
  defp flag_command("--help"), do: :help
  defp flag_command("-h"), do: :help
  defp flag_command(_), do: nil

  defp read_file(nil), do: {:ok, nil}
  defp read_file(path), do: ConfigFile.read(path)

  defp version_line do
    vsn = Application.spec(:bier, :vsn) || ~c"unknown"
    "bier #{vsn}\n"
  end

  defp usage do
    """
    Usage: bier [CONFIG_FILE] [OPTIONS]

    Runs Bier as a standalone PostgREST-compatible REST server. Config is read
    from PGRST_* environment variables, an optional CONFIG_FILE, and flags.

    Options:
      --dump-config   Print the loaded configuration and exit
      -v, --version   Print the version and exit
      -h, --help      Print this help and exit
    """
  end

  defp ok(stdout), do: %{stdout: stdout, stderr: "", exit: 0}
  defp error(message), do: %{stdout: "", stderr: [message, "\n"], exit: 1}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/cli_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/cli.ex test/bier/cli_test.exs
git commit -m "feat(#40): Bier.CLI.run/2 core dispatch"
```

---

## Task 7: escript wrapper + `to_start_opts/1` + mix.exs

Adds the thin escript entry point and the translation from a resolved config map to `Bier.start_link/1` keyword opts (used by the boot path). The boot path itself (start app, start one instance, block) is exercised by the release follow-up; here we unit-test the opts translation.

**Files:**
- Modify: `lib/bier/cli.ex`, `lib/bier/cli/config.ex`, `mix.exs`
- Test: `test/bier/cli/config_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/bier/cli/config_test.exs`:

```elixir
  describe "to_start_opts/1" do
    test "maps resolved keys to Bier.start_link/1 options" do
      {:ok, resolved} =
        Config.load(
          %{
            "PGRST_DB_URI" => "postgresql://alice:secret@db.example.com:5433/shop",
            "PGRST_DB_SCHEMAS" => "api,public",
            "PGRST_SERVER_PORT" => "4000",
            "PGRST_LOG_LEVEL" => "info"
          },
          nil,
          []
        )

      opts = Config.to_start_opts(resolved)

      assert opts[:hostname] == "db.example.com"
      assert opts[:port] == 5433
      assert opts[:database] == "shop"
      assert opts[:username] == "alice"
      assert opts[:password] == "secret"
      assert opts[:db_schemas] == ["api", "public"]
      assert opts[:log_level] == :info
      assert get_in(opts, [:router, :port]) == 4000
    end

    test "omits unset optional keys so Bier defaults apply" do
      {:ok, resolved} = Config.load(%{}, nil, [])
      opts = Config.to_start_opts(resolved)
      refute Keyword.has_key?(opts, :db_max_rows)
      refute Keyword.has_key?(opts, :jwt_secret)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/cli/config_test.exs`
Expected: FAIL — `function Bier.CLI.Config.to_start_opts/1 is undefined`.

- [ ] **Step 3: Implement `to_start_opts/1`**

Add to `lib/bier/cli/config.ex`:

```elixir
  @doc """
  Translate a resolved config map into a keyword list for `Bier.start_link/1`.
  `:unset` optional keys are omitted so Bier's own defaults apply. `db-uri` is
  parsed into discrete connection fields; `server-port` maps to `router[:port]`.
  """
  @spec to_start_opts(map()) :: keyword()
  def to_start_opts(resolved) do
    direct =
      [
        db_schemas: resolved["db-schemas"],
        db_anon_role: resolved["db-anon-role"],
        db_extra_search_path: resolved["db-extra-search-path"],
        db_max_rows: resolved["db-max-rows"],
        db_tx_end: resolved["db-tx-end"],
        db_pre_request: resolved["db-pre-request"],
        db_root_spec: resolved["db-root-spec"],
        admin_server_port: resolved["admin-server-port"],
        jwt_secret: resolved["jwt-secret"],
        jwt_aud: resolved["jwt-aud"],
        openapi_mode: resolved["openapi-mode"],
        log_level: resolved["log-level"],
        server_cors_allowed_origins: resolved["server-cors-allowed-origins"]
      ]
      |> Enum.reject(fn {_k, v} -> v == :unset end)

    router = [port: resolved["server-port"], scheme: :http]

    direct ++ [router: router] ++ db_uri_opts(resolved["db-uri"])
  end

  # Parse a libpq URI into Bier's discrete connection fields. An empty
  # "postgresql://" carries no fields, so Bier's defaults apply.
  defp db_uri_opts(uri) when uri in [nil, "", "postgresql://", "postgres://"], do: []

  defp db_uri_opts(uri) do
    %URI{host: host, port: port, path: path, userinfo: userinfo} = URI.parse(uri)
    {user, pass} = split_userinfo(userinfo)
    database = path |> to_string() |> String.trim_leading("/")

    [
      hostname: host,
      port: port,
      database: database,
      username: user,
      password: pass
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
  end

  defp split_userinfo(nil), do: {nil, nil}

  defp split_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] -> {user, pass}
      [user] -> {user, nil}
    end
  end
```

- [ ] **Step 4: Run the opts test to verify it passes**

Run: `mix test test/bier/cli/config_test.exs`
Expected: PASS.

- [ ] **Step 5: Add the escript `main/1` and the boot path**

Add to `lib/bier/cli.ex`:

```elixir
  @doc """
  escript entry point. Supplies the real process environment, writes the
  command's output to stdout/stderr, and halts with its exit code. For the
  default run action it boots one standalone Bier instance and blocks.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    case run(argv, env: System.get_env()) do
      {:boot, resolved} -> boot(resolved)
      %{stdout: out, stderr: err, exit: code} -> emit(out, err, code)
    end
  end

  defp emit(out, err, code) do
    IO.write(out)
    IO.write(:stderr, err)
    System.halt(code)
  end

  defp boot(resolved) do
    {:ok, _} = Application.ensure_all_started(:bier)
    {:ok, _pid} = Bier.start_link(Bier.CLI.Config.to_start_opts(resolved))
    Process.sleep(:infinity)
  end
```

- [ ] **Step 6: Configure the escript in mix.exs**

In `mix.exs`, add `escript: escript()` to the `project/0` keyword list (next to `aliases: aliases()`), and add the private function. `app: nil` prevents auto-starting the app, so `--dump-config` runs without a DB:

```elixir
  defp escript do
    [main_module: Bier.CLI, app: nil]
  end
```

- [ ] **Step 7: Verify the escript builds and runs**

Run: `mix escript.build && PGRST_LOG_LEVEL=info ./bier --dump-config`
Expected: prints the config including `log-level = "info"`, exits 0. Then:
Run: `./bier --version`
Expected: prints `bier <version>`, exits 0.
Run: `rm -f bier` (don't commit the built artifact; confirm it's git-ignored or remove it).

- [ ] **Step 8: Commit**

```bash
git add lib/bier/cli.ex lib/bier/cli/config.ex mix.exs test/bier/cli/config_test.exs
git commit -m "feat(#40): escript entry point + to_start_opts + boot path"
```

---

## Task 8: Conformance harness — CLI case path

Wires `kind: cli` cases through `Bier.CLI.run/2`: a `Bier.CliCase` template, the new assertions, and a test dispatch that defers only the explicitly-listed IDs.

**Files:**
- Create: `test/support/cli_case.ex`
- Modify: `test/support/conformance_assertions.ex`, `test/conformance/conformance_test.exs`

- [ ] **Step 1: Implement the CLI case template**

Create `test/support/cli_case.ex`:

```elixir
defmodule Bier.CliCase do
  @moduledoc """
  Drives a `kind: cli` conformance case through `Bier.CLI.run/2` in-process and
  returns a normalized `%{stdout, stderr, exit}` map (iodata flattened to
  strings). Any `config.file` map is written to a temp file; `config.env`
  becomes the env map passed to the core.
  """

  @doc "Run a CLI conformance case and return its normalized result."
  def perform(%Bier.ConformanceCase{request: req, config: config}) do
    env = Map.get(config, "env", %{})
    file_path = write_config_file(Map.get(config, "file"))
    argv = build_argv(Map.get(req, "flag"), file_path)

    try do
      result = Bier.CLI.run(argv, env: env)

      %{
        stdout: IO.iodata_to_binary(result.stdout),
        stderr: IO.iodata_to_binary(result.stderr),
        exit: result.exit
      }
    after
      if file_path, do: File.rm(file_path)
    end
  end

  # The case `flag` is either a CLI flag ("--dump-config") or a config-file
  # path that does not exist ("does_not_exist.conf", case 1719).
  defp build_argv(nil, file_path), do: List.wrap(file_path)
  defp build_argv("--" <> _ = flag, file_path), do: List.wrap(file_path) ++ [flag]
  defp build_argv(path, _file_path), do: [path]

  defp write_config_file(nil), do: nil

  defp write_config_file(file_map) do
    path = Path.join(System.tmp_dir!(), "bier_conf_#{System.unique_integer([:positive])}.conf")
    File.write!(path, render_file(file_map))
    path
  end

  defp render_file(file_map) do
    Enum.map_join(file_map, "\n", fn {k, v} -> "#{k} = #{render_value(v)}" end) <> "\n"
  end

  defp render_value(v) when is_binary(v), do: ~s("#{v}")
  defp render_value(v) when is_boolean(v), do: to_string(v)
  defp render_value(v) when is_integer(v), do: Integer.to_string(v)
end
```

- [ ] **Step 2: Add the CLI assertions**

In `test/support/conformance_assertions.ex`, add these `check/3` clauses **before** the catch-all `defp check(key, _val, _resp)` clause:

```elixir
  defp check("exit_code", "nonzero", resp) do
    assert resp.exit != 0, "expected nonzero exit, got #{resp.exit}\nstderr: #{resp.stderr}"
  end

  defp check("exit_code", expected, resp) do
    assert resp.exit == expected,
           "expected exit #{expected}, got #{resp.exit}\nstderr: #{resp.stderr}"
  end

  defp check("dump_contains", needles, resp) when is_list(needles) do
    Enum.each(needles, fn needle ->
      assert String.contains?(resp.stdout, needle),
             "dump did not contain #{inspect(needle)}\nfull dump:\n#{resp.stdout}"
    end)
  end

  defp check("stderr_contains", needle, resp) when is_binary(needle) do
    assert String.contains?(resp.stderr, needle),
           "stderr did not contain #{inspect(needle)}\nfull stderr:\n#{resp.stderr}"
  end

  defp check("dump_reparse_stable", true, resp) do
    path = Path.join(System.tmp_dir!(), "bier_reparse_#{System.unique_integer([:positive])}.conf")
    File.write!(path, resp.stdout)

    try do
      second = Bier.CLI.run(["--dump-config", path], env: %{})

      assert IO.iodata_to_binary(second.stdout) == resp.stdout,
             "re-dumping the dumped config was not byte-identical"
    after
      File.rm(path)
    end
  end
```

- [ ] **Step 3: Dispatch CLI cases in the conformance test**

In `test/conformance/conformance_test.exs`, add a module attribute listing the deferred IDs and their reason, and replace the `pending_reason` cond's `c.kind == :cli -> :cli` arm with a lookup. Then add an `else`-branch test body that runs the CLI path for non-deferred CLI cases.

Replace the `pending_reason =` cond block with:

```elixir
    pending_reason =
      cond do
        c.kind == :cli -> cli_pending_reason(c.id)
        Map.has_key?(c.request, "jwt") -> :jwt
        Map.has_key?(c.expect, "body_jsonpath") -> :jsonpath
        Map.has_key?(c.expect, "status_text") -> :status_text
        true -> nil
      end
```

Add near the top of the module (after `@moduletag :conformance`):

```elixir
  # CLI cases that map onto config Bier does not (yet) implement keep an honest
  # pending reason instead of a façade. See
  # docs/superpowers/specs/2026-06-07-cli-implementation-design.md.
  @cli_deferred %{
    1705 => :cli_parity,   # full default-table dump
    1727 => :cli_parity,   # --example template
    1707 => :unmodeled_key,
    1711 => :unmodeled_key,
    1714 => :unmodeled_key,
    1715 => :unmodeled_key,
    1716 => :unmodeled_key,
    1718 => :unmodeled_key,
    1729 => :unmodeled_key,
    1724 => :db_config,
    1725 => :db_config
  }

  defp cli_pending_reason(id), do: Map.get(@cli_deferred, id)
```

Change the runnable `test` body so CLI cases use the CLI path. Replace the existing `else` block's single `test` with a kind-aware version:

```elixir
    else
      test "#{c.id} #{c.feature}" do
        case_data = unquote(Macro.escape(c))

        resp =
          case case_data.kind do
            :cli -> Bier.CliCase.perform(case_data)
            :http -> perform(case_data)
          end

        assert_expect(resp, case_data.expect)
      end
    end
```

- [ ] **Step 4: Run the CLI conformance cases**

Run: `mix test test/conformance/conformance_test.exs --only area:config`
Expected: the non-deferred CLI cases (validation + dump for implemented keys) PASS; deferred ones are skipped as `:pending`. Note any case that fails and reconcile against the disposition table in the design doc — adjust `@cli_deferred` (with an honest reason) only if a case genuinely depends on an unmodeled key; otherwise fix the implementation.

- [ ] **Step 5: Commit**

```bash
git add test/support/cli_case.ex test/support/conformance_assertions.ex test/conformance/conformance_test.exs
git commit -m "feat(#40): conformance CLI case path + assertions"
```

---

## Task 9: Full verification + docs

**Files:**
- Modify: `spec/COVERAGE.md` (if it tracks pending reasons), `.gitignore` (if the `bier` escript artifact is not ignored)

- [ ] **Step 1: Confirm the escript artifact is ignored**

Run: `git check-ignore bier || echo "NOT IGNORED"`
If it prints `NOT IGNORED`, add `/bier` to `.gitignore` and commit:

```bash
echo "/bier" >> .gitignore
git add .gitignore
git commit -m "chore(#40): ignore built escript artifact"
```

- [ ] **Step 2: Run the CI gate commands**

Run each and confirm clean:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix docs --warnings-as-errors
mix test
```

Expected: all pass. CLI conformance cases that map onto implemented config are green; deferred cases report as pending with their reason.

- [ ] **Step 3: Update coverage docs**

If `spec/COVERAGE.md` enumerates pending reasons (it references the schema_cache deferral pattern), add the CLI dispositions: which `config` cases now pass and which remain pending as `:cli_parity` / `:unmodeled_key` / `:db_config`. Match the file's existing format.

- [ ] **Step 4: Commit**

```bash
git add spec/COVERAGE.md
git commit -m "docs(#40): record CLI conformance dispositions in COVERAGE.md"
```

---

## Self-Review (completed)

**Spec coverage:** in-process core + escript (Tasks 6/7) ✓; PostgREST dialect mapping incl. db-uri/server-port (Tasks 3/7) ✓; sources & precedence flags>env>file>default (Task 4) ✓; config-file subset + missing-file fatal (Task 2) ✓; shared validators with exact messages (Tasks 1/3/4) ✓; `--dump-config` PostgREST format + reparse-stable (Task 5) ✓; conformance harness path + new assertions + honest deferral (Task 8) ✓; honest disposition list matches the design doc's table (Task 8 `@cli_deferred`) ✓. Deferred-by-design (`--ready`, `--example`, release/Docker, db-config, unmodeled keys) are documented in Scope notes, not silently dropped.

**Placeholder scan:** no TBD/TODO; every code step shows complete code; every command shows expected output.

**Type consistency:** `Bier.CLI.Config.coerce/2`, `load/3`, `dump/1`, `to_start_opts/1`, `spec/0`; `Bier.CLI.ConfigFile.parse/1`/`read/1`; `Bier.Config.validate_jwt_secret/1`/`validate_jwt_aud/1`; `Bier.CLI.run/2` returns `%{stdout, stderr, exit}` or `{:boot, resolved}` consistently across Tasks 6–8; `Bier.CliCase.perform/1` flattens iodata to strings so the assertions' `String.contains?/2` calls hold.
