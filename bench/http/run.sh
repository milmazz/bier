#!/usr/bin/env bash
# HTTP benchmark: Bier vs PostgREST v14.12, natively on macOS.
#   bench/http/run.sh           full run (~50-60 min)
#   bench/http/run.sh --smoke   short windows, 1 round (~pipeline validation)
# Spec: docs/superpowers/specs/2026-07-09-http-benchmark-design.md
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BENCH_DIR/../.." && pwd)"
RESULTS="$BENCH_DIR/results"
BIN="$BENCH_DIR/bin"
PG_VERSION_PIN="v14.12"

BIER_PORT="${BIER_PORT:-3001}"
POSTGREST_PORT="${POSTGREST_PORT:-3002}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-$USER}"
export PGHOST PGPORT PGUSER

SCENARIOS=(r1 r2 m1 m2)
SMOKE=false
# Latency-stage arrival rate as a fraction of the slower server's closed-loop
# ceiling. Reads (r*) and writes (m*) get separate fractions: the closed-loop
# ceiling over-predicts open-loop sustainable throughput (during a GHC GC pause
# a closed-loop VU pool simply waits — coordinated omission — while an open-loop
# arrival stream keeps queueing; past the knee PostgREST queue-spirals into its
# 10s pool-acquisition timeout and never recovers). Probed on this rig for r1:
# 0.5-0.7 of the 60s closed-loop ceiling spiral 100% of the time; 0.4 sustains
# with zero drops while still measuring the GC pauses as p90/p99 tail — but
# only when probed cold. Ceilings are measured in the first minutes of the
# run; ~40 min of sustained load erodes effective capacity (thermal drift +
# Postgres background work from the write scenarios), and a full 3-round run
# at 0.4 of the cold ceiling spiraled PostgREST in round 3 (p99 74ms -> 556ms
# -> 2.7s across rounds at the same rate). 0.3 keeps the late-run effective
# fraction at/below the cold-probed 0.4 sustainable point. Writes (per-row
# INSERT/PATCH serialized through a pool of 10) knee even lower — 0.3, which
# showed no cross-round drift into the knee.
# Smoke uses gentler fractions: its 5s windows give a cold-started server no
# time to absorb a burst, its 5s closed-loop ceilings over-predict even more
# than the 60s ones (less GC exposure), and smoke validates the pipeline, not
# the numbers (observed: smoke reads at 0.4 on a warm rig drove PostgREST
# into its 10s pool-acquisition timeout — mass 5xx).
# Override any via the env.
# WARMUP/DURATION/ROUNDS/VUS are env-overridable around the per-mode defaults,
# e.g. `ROUNDS=1 bench/http/run.sh` for a single-round full run, or
# `WARMUP=10s DURATION=60s bench/http/run.sh --smoke` for a long-window smoke.
if [ "${1:-}" = "--smoke" ]; then
  SMOKE=true
  WARMUP="${WARMUP:-2s}"; DURATION="${DURATION:-5s}"
  ROUNDS="${ROUNDS:-1}"; VUS="${VUS:-25}"
  RATE_FRACTION_READ="${RATE_FRACTION_READ:-0.2}"
  RATE_FRACTION_WRITE="${RATE_FRACTION_WRITE:-0.2}"
else
  WARMUP="${WARMUP:-10s}"; DURATION="${DURATION:-60s}"
  ROUNDS="${ROUNDS:-3}"; VUS="${VUS:-100}"
  RATE_FRACTION_READ="${RATE_FRACTION_READ:-0.3}"
  RATE_FRACTION_WRITE="${RATE_FRACTION_WRITE:-0.3}"
fi

log() { printf '\n== %s\n' "$*"; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# ---------- file-descriptor budget ----------------------------------------
# The open-loop latency stage holds up to ~2000 concurrent sockets (k6
# preAllocatedVUs 1000 x2 scenarios). macOS launchd hands processes a default
# soft limit of 256 fds; under it the server's accept() loop dies mid-run with
# :emfile, the connection pool trips its supervisor's max-restart intensity, and
# k6 aborts the whole run with spurious `connection refused` failures. Raise it
# here so BOTH servers inherit the same budget (a fair comparison). No-op when
# the launching shell already grants more.
FD_TARGET=65536
if [ "$(ulimit -Sn)" -lt "$FD_TARGET" ]; then
  ulimit -n "$FD_TARGET" 2>/dev/null \
    || die "cannot raise fd limit to $FD_TARGET (hard limit $(ulimit -Hn)); rerun from a shell with a higher one"
fi

# ---------- prerequisites -------------------------------------------------
log "checking prerequisites"
log "fd limit: soft=$(ulimit -Sn) hard=$(ulimit -Hn)"
command -v psql >/dev/null || die "psql not found"
command -v curl >/dev/null || die "curl not found"
command -v mix  >/dev/null || die "mix not found"
command -v k6   >/dev/null || die "k6 not found: brew install k6"
command -v jq   >/dev/null || die "jq not found: brew install jq"
psql -X -d postgres -tAc "SELECT 1" >/dev/null || die "Postgres unreachable at $PGHOST:$PGPORT"

if [ ! -x "$BIN/postgrest" ]; then
  log "downloading postgrest $PG_VERSION_PIN"
  mkdir -p "$BIN"
  ARCH=$(uname -m); [ "$ARCH" = "arm64" ] && ARCH=aarch64
  curl -fSL "https://github.com/PostgREST/postgrest/releases/download/${PG_VERSION_PIN}/postgrest-${PG_VERSION_PIN}-macos-${ARCH}.tar.xz" \
    | tar -xJ -C "$BIN" || die "postgrest download failed — check asset names on the ${PG_VERSION_PIN} release page"
  chmod +x "$BIN/postgrest"
fi
"$BIN/postgrest" --version | grep -q "14.12" || die "wrong postgrest version in $BIN"

# ---------- database ------------------------------------------------------
log "loading bier_bench fixtures"
dropdb --if-exists bier_bench
createdb bier_bench
# -X everywhere: a user .psqlrc (e.g. \timing) would pollute captured output
psql -X -q -v ON_ERROR_STOP=1 -d bier_bench -f "$BENCH_DIR/fixtures.sql"

# PGPASSWORD must be URI-safe: it is embedded unencoded in BENCH_DB_URI.
if [ -n "${PGPASSWORD:-}" ]; then
  BENCH_DB_URI="postgres://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/bier_bench"
else
  BENCH_DB_URI="postgres://${PGUSER}@${PGHOST}:${PGPORT}/bier_bench"
fi
export BENCH_DB_URI POSTGREST_PORT BIER_PORT PGDATABASE=bier_bench

reset_events() {
  psql -X -q -d bier_bench -tAc "SELECT bench.reset_events()" >/dev/null
  # Fresh planner stats after TRUNCATE — a mis-planned first burst of UPDATEs
  # can queue-spiral a cold server. Separate call: ANALYZE cannot run in the
  # implicit transaction of a multi-statement -c.
  psql -X -q -d bier_bench -tAc "ANALYZE bench.events" >/dev/null
}

# ---------- server lifecycle ----------------------------------------------
SERVER_PID=""

kill_port_listener() { # $1=port — force-kill any process still LISTENing on it
  local pids
  pids=$(lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null || true)
  [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
}

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  # A killed launcher can orphan its child (mix -> BEAM) holding the port;
  # sweep both ports so a crashed run never strands a stale listener.
  kill_port_listener "$BIER_PORT"
  kill_port_listener "$POSTGREST_PORT"
}
trap cleanup EXIT

wait_up() { # $1=url
  for _ in $(seq 1 120); do
    curl -fsS -o /dev/null "$1" 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}

wait_down() { # $1=port
  for _ in $(seq 1 60); do
    curl -s -o /dev/null "http://127.0.0.1:$1/" 2>/dev/null || return 0
    sleep 0.5
  done
  return 1
}

ensure_port_free() { # $1=port — never boot over a stale listener from a dead run
  if lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; then
    die "port $1 already in use (stale server from a previous run? see: lsof -i :$1)"
  fi
}

start_server() { # $1=bier|postgrest
  local port; port=$([ "$1" = bier ] && echo "$BIER_PORT" || echo "$POSTGREST_PORT")
  ensure_port_free "$port"
  if [ "$1" = bier ]; then
    # exec so $! is the BEAM itself, not a subshell wrapper (kill must reach it)
    (cd "$ROOT" && exec env MIX_ENV=prod mix run --no-halt "$BENCH_DIR/start_bier.exs" \
      >"$RESULTS/bier.log" 2>&1) &
    SERVER_PID=$!
    wait_up "$(base_url bier)/items?limit=1" \
      || { tail -20 "$RESULTS/bier.log" >&2; die "bier failed to boot"; }
  else
    "$BIN/postgrest" "$BENCH_DIR/postgrest.conf" >"$RESULTS/postgrest.log" 2>&1 &
    SERVER_PID=$!
    wait_up "$(base_url postgrest)/items?limit=1" \
      || { tail -20 "$RESULTS/postgrest.log" >&2; die "postgrest failed to boot"; }
  fi
}

stop_server() { # $1=bier|postgrest
  local port; port=$([ "$1" = bier ] && echo "$BIER_PORT" || echo "$POSTGREST_PORT")
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    # Bounded graceful wait, then force. A lone SIGTERM + unbounded `wait`
    # hangs the entire run if the server ignores the signal (observed:
    # postgrest stuck for hours). Poll liveness for ~10s, then SIGKILL.
    for _ in $(seq 1 20); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.5
    done
    kill -9 "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
  # Reap an orphaned child (killed launcher) still holding the port.
  kill_port_listener "$port"
  wait_down "$port" || die "$1 did not release port $port"
}

base_url() { # $1=bier|postgrest
  [ "$1" = bier ] && echo "http://127.0.0.1:$BIER_PORT" || echo "http://127.0.0.1:$POSTGREST_PORT"
}

# ---------- ephemeral-port guard -------------------------------------------
# k6's arrival-rate executors round-robin iterations across the whole
# preallocated VU pool, and each VU touched opens its own keep-alive
# connection — a latency stage opens ~2x VUS_BASELINE connections regardless
# of actual concurrency, and every one sits in client-side TIME_WAIT for
# 2*MSL (30s on macOS) after the k6 process exits. Back-to-back short stages
# accumulate that residue faster than it expires and exhaust the 16,384-port
# ephemeral range (observed: EADDRNOTAVAIL dial failures at the 5th
# consecutive smoke latency stage). Wait for the pool to drain before each
# open-loop stage; residue expires in <=30s, so the wait is bounded.
wait_ephemeral_ports() {
  local tw=0
  for _ in $(seq 1 90); do
    tw=$(netstat -an -p tcp 2>/dev/null \
      | grep -E "127\.0\.0\.1\.($BIER_PORT|$POSTGREST_PORT)[^0-9]" \
      | grep -c TIME_WAIT || true)
    [ "$tw" -lt 1000 ] && return 0
    sleep 1
  done
  die "ephemeral-port pool did not drain ($tw TIME_WAIT sockets toward bench ports)"
}

# ---------- k6 wrapper ----------------------------------------------------
run_k6() { # $1=server $2=scenario $3=stage $4=rate $5=summary_file(or "-") $6=duration
  local summary=""
  [ "$5" != "-" ] && summary="$RESULTS/$5"
  BASE_URL="$(base_url "$1")" SCENARIO="$2" STAGE="$3" RATE="$4" VUS="$VUS" \
    WARMUP="$WARMUP" DURATION="$6" SUMMARY_PATH="$summary" \
    k6 run --quiet "$BENCH_DIR/scenarios.js" \
    || die "k6 failed ($1/$2/$3) — non-2xx or dropped iterations void the run"
}

measure() { # $1=server $2=scenario $3=stage $4=rate $5=summary_file
  reset_events
  if [ "$3" = latency ]; then
    wait_ephemeral_ports
    # One continuous k6 run: warmup flows into the measured window with no
    # idle gap (a gap stalls PostgREST's GHC idle GC and collapses the next
    # window). Warmup insert counts are equal by construction: same shared
    # arrival rate, zero-drop guard.
    run_k6 "$1" "$2" "$3" "$4" "$5" "$DURATION"
  else
    run_k6 "$1" "$2" "$3" "$4" - "$WARMUP"          # warmup, discarded
    reset_events                                     # identical table state at window start
    run_k6 "$1" "$2" "$3" "$4" "$5" "$DURATION"     # measured window
  fi
}

# ---------- parity probe ---------------------------------------------------
log "compiling bier (prod)"
(cd "$ROOT" && MIX_ENV=prod mix compile) >/dev/null

log "parity probe"
mkdir -p "$RESULTS"; rm -f "$RESULTS"/*.json "$RESULTS"/*.log "$RESULTS"/parity-* 2>/dev/null || true

probe() { # $1=server — captures status+body per scenario into parity files
  local base; base="$(base_url "$1")"
  reset_events
  curl -s -o "$RESULTS/parity-$1-r1.body" -w '%{http_code}' "$base/items?id=eq.42" >"$RESULTS/parity-$1-r1.status"
  curl -s -o "$RESULTS/parity-$1-r2.body" -w '%{http_code}' "$base/items?category=eq.category-05&order=id.desc&limit=25" >"$RESULTS/parity-$1-r2.status"
  curl -s -o /dev/null -w '%{http_code}' -X POST "$base/events" \
    -H 'Content-Type: application/json' -H 'Prefer: return=minimal' \
    -d '{"payload":"parity","occurred_at":"2026-07-09T00:00:00Z"}' >"$RESULTS/parity-$1-m1.status"
  curl -s -o /dev/null -w '%{http_code}' -X PATCH "$base/events?id=eq.1" \
    -H 'Content-Type: application/json' \
    -d '{"payload":"parity-patch"}' >"$RESULTS/parity-$1-m2.status"
}

for server in bier postgrest; do
  start_server "$server"; probe "$server"; stop_server "$server"
done
for s in r1 r2 m1 m2; do
  [ "$(cat "$RESULTS/parity-bier-$s.status")" = "$(cat "$RESULTS/parity-postgrest-$s.status")" ] \
    || die "parity: $s status differs (bier=$(cat "$RESULTS/parity-bier-$s.status") postgrest=$(cat "$RESULTS/parity-postgrest-$s.status"))"
done
for s in r1 r2; do
  diff <(jq -S . "$RESULTS/parity-bier-$s.body") <(jq -S . "$RESULTS/parity-postgrest-$s.body") >/dev/null \
    || die "parity: $s body differs — benchmarking unequal work is worse than no benchmark"
done
log "parity OK"

# ---------- stage 1: ceilings ----------------------------------------------
# macOS ships bash 3.2 (no associative arrays); store per-scenario rates in
# plain variables via eval-based accessors.
set_rate() { eval "RATE_$1=$2"; }
get_rate() { eval "echo \"\$RATE_$1\""; }

# Read scenarios (r*) and write scenarios (m*) draw from different fractions.
frac_for() { # $1=scenario
  case "$1" in
    r*) echo "$RATE_FRACTION_READ" ;;
    m*) echo "$RATE_FRACTION_WRITE" ;;
    *)  die "cannot classify scenario '$1' as read (r*) or write (m*)" ;;
  esac
}

for scenario in "${SCENARIOS[@]}"; do
  for server in bier postgrest; do
    log "ceiling: $scenario / $server"
    start_server "$server"
    measure "$server" "$scenario" ceiling 0 "$scenario-$server-ceiling.json"
    stop_server "$server"
  done
  b=$(jq '.metrics.http_reqs.values.rate' "$RESULTS/$scenario-bier-ceiling.json")
  p=$(jq '.metrics.http_reqs.values.rate' "$RESULTS/$scenario-postgrest-ceiling.json")
  f=$(frac_for "$scenario")
  set_rate "$scenario" "$(jq -n --argjson a "$b" --argjson b "$p" --argjson f "$f" '([$a, $b] | min * $f | floor)')"
  [ "$(get_rate "$scenario")" -ge 1 ] || die "computed arrival rate < 1 req/s for $scenario"
  log "ceilings $scenario: bier=$b postgrest=$p -> shared rate $(get_rate "$scenario") (frac $f)"
done

# ---------- stage 2: latency rounds (counterbalanced A/B, B/A, ...) ---------
for round in $(seq 1 "$ROUNDS"); do
  # Alternate boot order per round so neither server always occupies the
  # cooler first slot.
  if [ $((round % 2)) -eq 1 ]; then servers=(bier postgrest); else servers=(postgrest bier); fi
  for scenario in "${SCENARIOS[@]}"; do
    for server in "${servers[@]}"; do
      log "latency: $scenario / $server / round $round @ $(get_rate "$scenario") req/s"
      start_server "$server"
      measure "$server" "$scenario" latency "$(get_rate "$scenario")" "$scenario-$server-latency-r$round.json"
      stop_server "$server"
    done
  done
done

# ---------- meta + report ----------------------------------------------------
log "writing meta.json and REPORT.md"
jq -n \
  --arg date "$(date '+%Y-%m-%d')" \
  --arg hardware "$(sysctl -n machdep.cpu.brand_string)" \
  --argjson memory_gb "$(($(sysctl -n hw.memsize) / 1073741824))" \
  --arg os "macOS $(sw_vers -productVersion)" \
  --arg elixir "$(elixir --short-version 2>/dev/null || elixir -e 'IO.puts(System.version())')" \
  --arg otp "$(erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().')" \
  --arg postgres "$(psql -X -d bier_bench -tAc 'SHOW server_version')" \
  --arg postgrest "$PG_VERSION_PIN" \
  --arg k6 "$(k6 version | head -1)" \
  --arg bier "$(cd "$ROOT" && mix run -e 'IO.puts(Mix.Project.config()[:version])' --no-start 2>/dev/null | tail -1)" \
  --argjson rounds "$ROUNDS" --arg warmup "$WARMUP" --arg duration "$DURATION" \
  --argjson smoke "$SMOKE" \
  --argjson rate_fraction "$(jq -n --argjson r "$RATE_FRACTION_READ" \
    --argjson w "$RATE_FRACTION_WRITE" '{read: $r, write: $w}')" \
  --argjson rates "$(jq -n \
    --argjson r1 "$(get_rate r1)" --argjson r2 "$(get_rate r2)" \
    --argjson m1 "$(get_rate m1)" --argjson m2 "$(get_rate m2)" \
    '{r1: $r1, r2: $r2, m1: $m1, m2: $m2}')" \
  '{date: $date, hardware: $hardware, memory_gb: $memory_gb, os: $os,
    elixir: $elixir, otp: $otp, postgres: $postgres, postgrest: $postgrest,
    k6: $k6, bier: $bier, rounds: $rounds, warmup: $warmup,
    duration: $duration, smoke: $smoke, rate_fraction: $rate_fraction,
    rates: $rates}' \
  >"$RESULTS/meta.json"

elixir "$BENCH_DIR/report.exs" "$RESULTS"
log "done — bench/http/REPORT.md"
