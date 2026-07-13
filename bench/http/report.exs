# Renders bench/http/REPORT.md from the k6 summaries written by run.sh.
#   elixir bench/http/report.exs [results_dir]     # default bench/http/results
# Pure stdlib (Elixir 1.18+ JSON) — no deps, no repo compilation needed.

defmodule BenchReport do
  @scenarios [
    {"r1", "R1 — single row by PK", "`GET /items?id=eq.<id>`"},
    {"r2", "R2 — filtered 25-row page", "`GET /items?category=eq.<cat>&order=id.desc&limit=25`"},
    {"m1", "M1 — insert", "`POST /events` (`Prefer: return=minimal`)"},
    {"m2", "M2 — update by PK", "`PATCH /events?id=eq.<id>`"}
  ]
  @servers ["bier", "postgrest"]
  @trend_keys [{"med", "p50"}, {"p(90)", "p90"}, {"p(99)", "p99"}]

  def main([]), do: main(["bench/http/results"])

  def main([dir]) do
    meta = load!(Path.join(dir, "meta.json"))
    rounds = meta["rounds"]
    sections = Enum.map(@scenarios, &section(&1, dir, rounds, meta))
    out = Path.join(Path.dirname(Path.expand(dir)), "REPORT.md")
    File.write!(out, render(meta, sections))
    IO.puts("wrote #{out}")
  end

  defp load!(path) do
    case File.read(path) do
      {:ok, body} ->
        data = JSON.decode!(body)
        assert_no_failures!(path, data)
        data

      {:error, reason} ->
        IO.puts(:stderr, "missing result file: #{path} (#{reason})")
        System.halt(1)
    end
  end

  # k6 summaries carry http_req_failed as a rate metric; `passes` counts
  # failed requests (the rate's numerator). Anything non-zero voids the run.
  defp assert_no_failures!(path, %{"metrics" => %{"http_req_failed" => failed}}) do
    if failed["values"]["passes"] > 0 do
      IO.puts(:stderr, "#{path}: #{failed["values"]["passes"]} failed requests — run is void")
      System.halt(1)
    end
  end

  defp assert_no_failures!(_path, _data), do: :ok

  # A latency stage is only meaningful open-loop: if k6 dropped iterations
  # (warmup phase included — a starved warmup poisons the measured window) or
  # the measured phase missed the shared target arrival rate, the stage
  # degraded into a closed-loop test and the cross-server comparison is void.
  # The rate check derives the measured phase's achieved rate from its
  # request count over the configured duration (a counter sub-metric's `rate`
  # in the summary is diluted by the warmup phase's share of wall clock); it
  # is skipped for smoke runs, where 5s windows make edge effects dominate.
  defp assert_open_loop!(path, %{"metrics" => metrics}, target_rate, meta) do
    dropped = get_in(metrics, ["dropped_iterations", "values", "count"]) || 0

    if dropped > 0 do
      IO.puts(
        :stderr,
        "#{path}: #{dropped} dropped iterations — target rate not sustained, run is void"
      )

      System.halt(1)
    end

    duration_s = meta["duration"] |> String.trim_trailing("s") |> String.to_integer()
    count = get_in(metrics, ["http_reqs{phase:measure}", "values", "count"]) || 0
    achieved = count / duration_s

    if !meta["smoke"] and abs(achieved - target_rate) > target_rate * 0.05 do
      IO.puts(
        :stderr,
        "#{path}: achieved #{achieved} req/s vs target #{target_rate} — run is void"
      )

      System.halt(1)
    end
  end

  defp section({id, title, request}, dir, rounds, meta) do
    ceilings =
      Map.new(@servers, fn s ->
        {s,
         load!(Path.join(dir, "#{id}-#{s}-ceiling.json"))["metrics"]["http_reqs"]["values"][
           "rate"
         ]}
      end)

    latencies =
      Map.new(@servers, fn s ->
        rows =
          for r <- 1..rounds do
            path = Path.join(dir, "#{id}-#{s}-latency-r#{r}.json")
            summary = load!(path)
            assert_open_loop!(path, summary, meta["rates"][id], meta)
            summary["metrics"]["http_req_duration{phase:measure}"]["values"]
          end

        {s, rows}
      end)

    rate = meta["rates"][id]

    rows =
      [
        {"Max throughput (req/s)", :higher, Map.new(@servers, &{&1, {ceilings[&1], nil, nil}})}
      ] ++
        for {k6_key, label} <- @trend_keys do
          per_server =
            Map.new(@servers, fn s ->
              vals = Enum.map(latencies[s], & &1[k6_key])
              {s, {median(vals), Enum.min(vals), Enum.max(vals)}}
            end)

          {"#{label} latency (ms)", :lower, per_server}
        end

    """
    ## #{title}

    Request: #{request} — latency measured at a shared arrival rate of **#{rate} req/s**.

    | Metric | Bier | PostgREST | Bier / PostgREST |
    |---|---|---|---|
    #{Enum.map_join(rows, "\n", &row/1)}
    """
  end

  defp row({label, direction, per_server}) do
    {b, bmin, bmax} = per_server["bier"]
    {p, pmin, pmax} = per_server["postgrest"]
    note = if direction == :lower, do: " (lower is better)", else: ""
    "| #{label} | #{cell(b, bmin, bmax)} | #{cell(p, pmin, pmax)} | #{ratio(b, p)}#{note} |"
  end

  defp cell(v, nil, nil), do: fmt(v)
  defp cell(v, min, max), do: "#{fmt(v)} (#{fmt(min)}–#{fmt(max)})"

  # JSON has no int/float distinction: k6's JSON.stringify drops the ".0" on
  # whole-number metrics, so decoded values may be integers. Compare with ==
  # (catches 0, 0.0 and -0.0) and normalize via `* 1.0` before formatting.
  defp ratio(_b, p) when p == 0, do: "n/a"
  defp ratio(b, p), do: "#{fmt(b / p)}x"

  defp fmt(v) when is_number(v), do: :erlang.float_to_binary(v * 1.0, decimals: 2)
  defp fmt(v), do: to_string(v)

  defp median(vals) do
    sorted = Enum.sort(vals)
    n = length(sorted)

    if rem(n, 2) == 1 do
      Enum.at(sorted, div(n, 2))
    else
      (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2
    end
  end

  defp render(meta, sections) do
    smoke_warning =
      if meta["smoke"],
        do:
          "\n> **SMOKE RUN** — shortened windows; numbers are pipeline-validation only, not citable.\n",
        else: ""

    """
    # HTTP benchmark: Bier vs PostgREST v#{String.trim_leading(meta["postgrest"], "v")}

    > Generated by `bench/http/run.sh` on #{meta["date"]}. Do not edit by hand.
    #{smoke_warning}
    ## Environment

    | | |
    |---|---|
    | Hardware | #{meta["hardware"]}, #{meta["memory_gb"]} GB |
    | OS | #{meta["os"]} |
    | Elixir / OTP | #{meta["elixir"]} / #{meta["otp"]} |
    | PostgreSQL | #{meta["postgres"]} |
    | PostgREST | #{meta["postgrest"]} |
    | Bier | #{meta["bier"]} |
    | k6 | #{meta["k6"]} |

    #{Enum.join(sections, "\n")}
    ## Methodology

    Both servers ran natively on the machine above against the same local
    PostgreSQL and the `bier_bench` database (`bench/http/fixtures.sql`:
    100k-row `bench.items`, `bench.events` reset to a 10k-row baseline before
    every round). Config parity: pool size 10, schema `bench`, anon role
    `bench_anon`, no JWT, logging off, no compression, HTTP/1.1 keep-alive.

    Per scenario: a closed-loop ceiling stage (constant VUs, once per server)
    found max throughput; then #{meta["rounds"]} interleaved A/B rounds of an
    open-loop `constant-arrival-rate` stage at
    #{round(meta["rate_fraction"]["read"] * 100)}% (reads) / #{round(meta["rate_fraction"]["write"] * 100)}% (writes) of the slower server's ceiling
    (the shared rate above) measured latency, immune to coordinated
    omission. Each stage: #{meta["warmup"]} discarded warmup +
    #{meta["duration"]} measurement; the latency stage runs warmup and
    measurement as one continuous arrival stream (no idle gap between k6
    runs — a gap was observed to stall PostgREST's GHC idle GC) and reports
    only the measured phase. Only the measured server ran during a
    stage. Latency cells show median across rounds (min–max). Any non-2xx
    response, dropped iteration, or >5% miss of the shared arrival rate
    aborts the run. Full details:
    `docs/superpowers/specs/2026-07-09-http-benchmark-design.md`.
    """
  end
end

BenchReport.main(System.argv())
