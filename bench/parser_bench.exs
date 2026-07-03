# Benchee comparison of the QueryParser leaf grammars: regex/string (current
# default) vs nimble_parsec twins, plus an end-to-end `parse_request/1`
# comparison over a realistic query-string mix.
#
#   MIX_ENV=dev mix run bench/parser_bench.exs
#
# Each `Benchee.run` measures ips, median run time, and memory (memory_time).
# The corpus comes from bench/corpus.exs (conformance-derived + edge cases).

Code.require_file("corpus.exs", __DIR__)
Code.require_file("regex_ref.exs", __DIR__)

alias Bier.QueryParser, as: QP
alias Bier.QueryParser, as: N
alias Bench.RegexRef
alias Bench.Corpus

bench_opts = [
  warmup: 0.5,
  time: 2,
  memory_time: 1,
  print: [fast_warning: false],
  formatters: [{Benchee.Formatters.Console, extended_statistics: false}]
]

# Drive a whole input list per invocation so a single run reflects realistic
# mixed input (and so memory numbers aren't dominated by call overhead).
run = fn name, inputs, regex_fun, nimble_fun ->
  IO.puts("\n\n########## #{name} (#{length(inputs)} inputs/run) ##########")

  Benchee.run(
    %{
      "regex" => fn -> Enum.each(inputs, regex_fun) end,
      "nimble" => fn -> Enum.each(inputs, nimble_fun) end
    },
    bench_opts
  )
end

run.(
  "parse_json_path/1",
  Corpus.json_paths(),
  &RegexRef.parse_json_path/1,
  &N.parse_json_path/1
)

run.(
  "split_op_value/1",
  Corpus.op_values(),
  &RegexRef.split_op_value/1,
  &N.split_op_value/1
)

run.(
  "valid_identifier?/1",
  Corpus.identifiers(),
  &RegexRef.valid_identifier?/1,
  &N.valid_identifier?/1
)

run.(
  "embed?/1",
  Corpus.embed_fields(),
  &RegexRef.embed?/1,
  &N.embed?/1
)

run.(
  "aggregate?/1",
  Corpus.aggregate_fields(),
  &RegexRef.aggregate?/1,
  &N.aggregate?/1
)

run.(
  "split_alias/1",
  Corpus.scalar_selects() ++ Corpus.embed_fields(),
  &RegexRef.split_alias/1,
  &N.split_alias/1
)

run.(
  "parse_scalar_select/1",
  Corpus.scalar_selects(),
  &RegexRef.parse_scalar_select/1,
  &N.parse_scalar_select/1
)

run.(
  "parse_filter_expr/2",
  Corpus.filter_exprs(),
  fn {c, o} -> RegexRef.parse_filter_expr(c, o) end,
  fn {c, o} -> N.parse_filter_expr(c, o) end
)

run.(
  "parse_order_term/1",
  Corpus.order_terms(),
  &RegexRef.parse_order_term/1,
  &N.parse_order_term/1
)

# ---- end-to-end parse_request/1, both backends ----------------------------

mix = Corpus.request_mix()

IO.puts(
  "\n\n########## parse_request/1 (end-to-end, #{length(mix)} query strings/run) ##########"
)

Benchee.run(
  %{
    "regex" => fn ->
      Application.put_env(:bier, :parser_backend, :regex)
      Enum.each(mix, &QP.parse_request/1)
    end,
    "nimble" => fn ->
      Application.put_env(:bier, :parser_backend, :nimble)
      Enum.each(mix, &QP.parse_request/1)
    end
  },
  bench_opts
)

Application.put_env(:bier, :parser_backend, :regex)
