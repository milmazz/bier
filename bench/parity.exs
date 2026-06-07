# Parity check: assert the regex and nimble backends return IDENTICAL results
# for every corpus input, per leaf function AND end-to-end through
# `parse_request/1`. Any mismatch is a bug.
#
#   MIX_ENV=dev mix run bench/parity.exs
#
# The per-function regex references below are faithful copies of the private
# implementations in `Bier.QueryParser` (kept here so we can call them directly;
# the module's twins are private). The end-to-end check instead flips the real
# `:parser_backend` app env so it exercises the production dispatch.

Code.require_file("corpus.exs", __DIR__)
Code.require_file("regex_ref.exs", __DIR__)

alias Bier.QueryParser, as: QP
alias Bier.QueryParser.Nimble, as: N
alias Bench.RegexRef

defmodule Parity do
  @moduledoc false

  def check(label, inputs, regex_fun, nimble_fun) do
    {ok, mismatches} =
      Enum.reduce(inputs, {0, []}, fn input, {ok, bad} ->
        r = apply_fun(regex_fun, input)
        n = apply_fun(nimble_fun, input)

        if r == n do
          {ok + 1, bad}
        else
          {ok, [{input, r, n} | bad]}
        end
      end)

    total = length(inputs)
    status = if mismatches == [], do: "OK", else: "MISMATCH"
    IO.puts("  #{String.pad_trailing(label, 22)} #{ok}/#{total} identical  [#{status}]")

    Enum.each(Enum.reverse(mismatches), fn {input, r, n} ->
      IO.puts("    ! input=#{inspect(input)}")
      IO.puts("        regex : #{inspect(r)}")
      IO.puts("        nimble: #{inspect(n)}")
    end)

    {ok, total, mismatches == []}
  end

  defp apply_fun(fun, {a, b}), do: fun.(a, b)
  defp apply_fun(fun, x), do: fun.(x)
end

IO.puts("== Per-function parity (regex reference vs nimble) ==")

results = [
  Parity.check(
    "parse_json_path",
    Bench.Corpus.json_paths(),
    &RegexRef.parse_json_path/1,
    &N.parse_json_path/1
  ),
  Parity.check(
    "split_op_value",
    Bench.Corpus.op_values(),
    &RegexRef.split_op_value/1,
    &N.split_op_value/1
  ),
  Parity.check(
    "valid_identifier?",
    Bench.Corpus.identifiers(),
    &RegexRef.valid_identifier?/1,
    &N.valid_identifier?/1
  ),
  Parity.check(
    "embed?",
    Bench.Corpus.embed_fields(),
    &RegexRef.embed?/1,
    &N.embed?/1
  ),
  Parity.check(
    "aggregate?",
    Bench.Corpus.aggregate_fields(),
    &RegexRef.aggregate?/1,
    &N.aggregate?/1
  ),
  Parity.check(
    "split_alias",
    Bench.Corpus.scalar_selects() ++ Bench.Corpus.embed_fields(),
    &RegexRef.split_alias/1,
    &N.split_alias/1
  ),
  Parity.check(
    "parse_scalar_select",
    Bench.Corpus.scalar_selects(),
    &RegexRef.parse_scalar_select/1,
    &N.parse_scalar_select/1
  ),
  Parity.check(
    "parse_filter_expr",
    Bench.Corpus.filter_exprs(),
    &RegexRef.parse_filter_expr/2,
    &N.parse_filter_expr/2
  ),
  Parity.check(
    "parse_order_term",
    Bench.Corpus.order_terms(),
    &RegexRef.parse_order_term/1,
    &N.parse_order_term/1
  )
]

IO.puts("\n== End-to-end parity: parse_request/1 (:regex vs :nimble app env) ==")

mix = Bench.Corpus.request_mix()

{e2e_ok, e2e_bad} =
  Enum.reduce(mix, {0, []}, fn qs, {ok, bad} ->
    Application.put_env(:bier, :parser_backend, :regex)
    r = QP.parse_request(qs)
    Application.put_env(:bier, :parser_backend, :nimble)
    n = QP.parse_request(qs)
    Application.put_env(:bier, :parser_backend, :regex)

    if r == n, do: {ok + 1, bad}, else: {ok, [{qs, r, n} | bad]}
  end)

IO.puts(
  "  parse_request          #{e2e_ok}/#{length(mix)} identical  [" <>
    if(e2e_bad == [], do: "OK", else: "MISMATCH") <> "]"
)

Enum.each(Enum.reverse(e2e_bad), fn {qs, r, n} ->
  IO.puts("    ! qs=#{inspect(qs)}")
  IO.puts("        regex : #{inspect(r)}")
  IO.puts("        nimble: #{inspect(n)}")
end)

all_ok? = Enum.all?(results, fn {_o, _t, ok?} -> ok? end) and e2e_bad == []

IO.puts("\n#{if all_ok?, do: "ALL PARITY CHECKS PASSED", else: "PARITY FAILURES PRESENT"}")
unless all_ok?, do: System.halt(1)
