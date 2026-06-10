# Generated from lib/bier/query_parser.ex.exs, do not edit.
# Generated at 2026-06-10 05:35:05Z.

defmodule Bier.QueryParser do
  @moduledoc """
  Parser for SQL queries given via query strings

  > #### Generated file {: .info}
  >
  > The committed `lib/bier/query_parser.ex` is **generated** from this template
  > (`lib/bier/query_parser.ex.exs`) via `mix gen.parsers`, which runs
  > `mix nimble_parsec.compile`. Only the legacy `select`/`horizontal_filter`
  > combinators between the `parsec` marker comments are expanded; everything
  > else passes through verbatim. The generated `.ex` has no runtime
  > dependency on `nimble_parsec` (a `:dev`-only dependency). Edit this template
  > and re-run `mix gen.parsers`; never edit the `.ex` directly.
  """

  alias Bier.QueryParser.Nimble

  @spec horizontal_filter(binary, keyword) ::
          {:ok, [term], rest, context, line, byte_offset}
          | {:error, reason, rest, context, line, byte_offset}
        when line: {pos_integer, byte_offset},
             byte_offset: non_neg_integer,
             rest: binary,
             reason: String.t(),
             context: map
  defp horizontal_filter(binary, opts \\ []) when is_binary(binary) do
    context = Map.new(Keyword.get(opts, :context, []))
    byte_offset = Keyword.get(opts, :byte_offset, 0)

    line =
      case Keyword.get(opts, :line, 1) do
        {_, _} = line -> line
        line -> {line, byte_offset}
      end

    case horizontal_filter__0(binary, [], [], context, line, byte_offset) do
      {:ok, acc, rest, context, line, offset} ->
        {:ok, :lists.reverse(acc), rest, context, line, offset}

      {:error, _, _, _, _, _} = error ->
        error
    end
  end

  defp horizontal_filter__0(
         <<"not", x0, rest::binary>>,
         acc,
         stack,
         context,
         comb__line,
         comb__offset
       )
       when x0 === 46 do
    horizontal_filter__1(
      rest,
      [negation?: true] ++ acc,
      stack,
      context,
      comb__line,
      comb__offset + 4
    )
  end

  defp horizontal_filter__0(<<rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    horizontal_filter__1(rest, [] ++ acc, stack, context, comb__line, comb__offset)
  end

  defp horizontal_filter__1(rest, acc, stack, context, line, offset) do
    horizontal_filter__31(
      rest,
      [],
      [{rest, context, line, offset}, acc | stack],
      context,
      line,
      offset
    )
  end

  defp horizontal_filter__3(rest, acc, stack, context, line, offset) do
    horizontal_filter__4(rest, [], [acc | stack], context, line, offset)
  end

  defp horizontal_filter__4(rest, acc, stack, context, line, offset) do
    horizontal_filter__5(rest, [], [acc | stack], context, line, offset)
  end

  defp horizontal_filter__5(<<"eq", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    horizontal_filter__6(rest, ["="] ++ acc, stack, context, comb__line, comb__offset + 2)
  end

  defp horizontal_filter__5(
         <<"gte", rest::binary>>,
         acc,
         stack,
         context,
         comb__line,
         comb__offset
       ) do
    horizontal_filter__6(rest, [">="] ++ acc, stack, context, comb__line, comb__offset + 3)
  end

  defp horizontal_filter__5(<<"gt", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    horizontal_filter__6(rest, [">"] ++ acc, stack, context, comb__line, comb__offset + 2)
  end

  defp horizontal_filter__5(
         <<"lte", rest::binary>>,
         acc,
         stack,
         context,
         comb__line,
         comb__offset
       ) do
    horizontal_filter__6(rest, ["<="] ++ acc, stack, context, comb__line, comb__offset + 3)
  end

  defp horizontal_filter__5(<<"lt", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    horizontal_filter__6(rest, ["<"] ++ acc, stack, context, comb__line, comb__offset + 2)
  end

  defp horizontal_filter__5(
         <<"neq", rest::binary>>,
         acc,
         stack,
         context,
         comb__line,
         comb__offset
       ) do
    horizontal_filter__6(rest, ["<>"] ++ acc, stack, context, comb__line, comb__offset + 3)
  end

  defp horizontal_filter__5(<<"in", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    horizontal_filter__6(rest, ["in"] ++ acc, stack, context, comb__line, comb__offset + 2)
  end

  defp horizontal_filter__5(rest, _acc, _stack, context, line, offset) do
    {:error,
     "expected string \"is\", followed by ASCII character equal to \".\", followed by string \"false\" or string \"true\" or string \"like\" or string \"ilike\", followed by ASCII character equal to \".\", followed by ASCII character equal to \"*\" or ASCII character, followed by end of string or string \"eq\" or string \"gte\" or string \"gt\" or string \"lte\" or string \"lt\" or string \"neq\" or string \"in\", followed by ASCII character equal to \".\", followed by ASCII character, followed by end of string",
     rest, context, line, offset}
  end

  defp horizontal_filter__6(rest, user_acc, [acc | stack], context, line, offset) do
    case (case normalize(rest, user_acc, context, line, offset) do
            {_, _, _} = res ->
              res

            {:error, reason} ->
              {:error, reason}

            {acc, context} ->
              IO.warn(
                "returning a two-element tuple {acc, context} in pre_traverse/post_traverse is deprecated, " <>
                  "please return {rest, acc, context} instead"
              )

              {rest, acc, context}
          end) do
      {rest, user_acc, context} when is_list(user_acc) ->
        horizontal_filter__7(rest, user_acc ++ acc, stack, context, line, offset)

      {:error, reason} ->
        {:error, reason, rest, context, line, offset}
    end
  end

  defp horizontal_filter__7(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc

    horizontal_filter__8(
      rest,
      [operator: :lists.reverse(user_acc)] ++ acc,
      stack,
      context,
      line,
      offset
    )
  end

  defp horizontal_filter__8(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 46 do
    horizontal_filter__9(rest, [] ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp horizontal_filter__8(rest, _acc, _stack, context, line, offset) do
    {:error,
     "expected string \"is\", followed by ASCII character equal to \".\", followed by string \"false\" or string \"true\" or string \"like\" or string \"ilike\", followed by ASCII character equal to \".\", followed by ASCII character equal to \"*\" or ASCII character, followed by end of string or string \"eq\" or string \"gte\" or string \"gt\" or string \"lte\" or string \"lt\" or string \"neq\" or string \"in\", followed by ASCII character equal to \".\", followed by ASCII character, followed by end of string",
     rest, context, line, offset}
  end

  defp horizontal_filter__9(rest, acc, stack, context, line, offset) do
    horizontal_filter__10(rest, [], [acc | stack], context, line, offset)
  end

  defp horizontal_filter__10(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    horizontal_filter__12(
      rest,
      [x0] ++ acc,
      stack,
      context,
      (
        line = comb__line

        case x0 do
          10 -> {elem(line, 0) + 1, comb__offset + 1}
          _ -> line
        end
      ),
      comb__offset + 1
    )
  end

  defp horizontal_filter__10(rest, acc, stack, context, line, offset) do
    horizontal_filter__11(rest, acc, stack, context, line, offset)
  end

  defp horizontal_filter__12(rest, acc, stack, context, line, offset) do
    horizontal_filter__10(rest, acc, stack, context, line, offset)
  end

  defp horizontal_filter__11(<<""::binary>>, acc, stack, context, comb__line, comb__offset) do
    horizontal_filter__13("", [] ++ acc, stack, context, comb__line, comb__offset)
  end

  defp horizontal_filter__11(rest, _acc, _stack, context, line, offset) do
    {:error,
     "expected string \"is\", followed by ASCII character equal to \".\", followed by string \"false\" or string \"true\" or string \"like\" or string \"ilike\", followed by ASCII character equal to \".\", followed by ASCII character equal to \"*\" or ASCII character, followed by end of string or string \"eq\" or string \"gte\" or string \"gt\" or string \"lte\" or string \"lt\" or string \"neq\" or string \"in\", followed by ASCII character equal to \".\", followed by ASCII character, followed by end of string",
     rest, context, line, offset}
  end

  defp horizontal_filter__13(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc

    horizontal_filter__14(
      rest,
      [value: :lists.reverse(user_acc)] ++ acc,
      stack,
      context,
      line,
      offset
    )
  end

  defp horizontal_filter__14(rest, acc, [_, previous_acc | stack], context, line, offset) do
    horizontal_filter__2(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp horizontal_filter__15(_, _, [{rest, context, line, offset} | _] = stack, _, _, _) do
    horizontal_filter__3(rest, [], stack, context, line, offset)
  end

  defp horizontal_filter__16(rest, acc, stack, context, line, offset) do
    horizontal_filter__17(rest, [], [acc | stack], context, line, offset)
  end

  defp horizontal_filter__17(rest, acc, stack, context, line, offset) do
    horizontal_filter__18(rest, [], [acc | stack], context, line, offset)
  end

  defp horizontal_filter__18(
         <<"like", rest::binary>>,
         acc,
         stack,
         context,
         comb__line,
         comb__offset
       ) do
    horizontal_filter__19(rest, ["like"] ++ acc, stack, context, comb__line, comb__offset + 4)
  end

  defp horizontal_filter__18(
         <<"ilike", rest::binary>>,
         acc,
         stack,
         context,
         comb__line,
         comb__offset
       ) do
    horizontal_filter__19(rest, ["ilike"] ++ acc, stack, context, comb__line, comb__offset + 5)
  end

  defp horizontal_filter__18(rest, _acc, stack, context, line, offset) do
    [_, acc | stack] = stack
    horizontal_filter__15(rest, acc, stack, context, line, offset)
  end

  defp horizontal_filter__19(rest, user_acc, [acc | stack], context, line, offset) do
    case (case normalize(rest, user_acc, context, line, offset) do
            {_, _, _} = res ->
              res

            {:error, reason} ->
              {:error, reason}

            {acc, context} ->
              IO.warn(
                "returning a two-element tuple {acc, context} in pre_traverse/post_traverse is deprecated, " <>
                  "please return {rest, acc, context} instead"
              )

              {rest, acc, context}
          end) do
      {rest, user_acc, context} when is_list(user_acc) ->
        horizontal_filter__20(rest, user_acc ++ acc, stack, context, line, offset)

      {:error, reason} ->
        {:error, reason, rest, context, line, offset}
    end
  end

  defp horizontal_filter__20(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc

    horizontal_filter__21(
      rest,
      [operator: :lists.reverse(user_acc)] ++ acc,
      stack,
      context,
      line,
      offset
    )
  end

  defp horizontal_filter__21(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 46 do
    horizontal_filter__22(rest, [] ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp horizontal_filter__21(rest, acc, stack, context, line, offset) do
    horizontal_filter__15(rest, acc, stack, context, line, offset)
  end

  defp horizontal_filter__22(rest, acc, stack, context, line, offset) do
    horizontal_filter__23(rest, [], [acc | stack], context, line, offset)
  end

  defp horizontal_filter__23(rest, acc, stack, context, line, offset) do
    horizontal_filter__25(
      rest,
      [],
      [{rest, acc, context, line, offset} | stack],
      context,
      line,
      offset
    )
  end

  defp horizontal_filter__25(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 42 do
    horizontal_filter__26(rest, ~c"%" ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp horizontal_filter__25(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    horizontal_filter__26(
      rest,
      [x0] ++ acc,
      stack,
      context,
      (
        line = comb__line

        case x0 do
          10 -> {elem(line, 0) + 1, comb__offset + 1}
          _ -> line
        end
      ),
      comb__offset + 1
    )
  end

  defp horizontal_filter__25(rest, acc, stack, context, line, offset) do
    horizontal_filter__24(rest, acc, stack, context, line, offset)
  end

  defp horizontal_filter__24(_, _, [{rest, acc, context, line, offset} | stack], _, _, _) do
    horizontal_filter__27(rest, acc, stack, context, line, offset)
  end

  defp horizontal_filter__26(
         inner_rest,
         inner_acc,
         [{rest, acc, context, line, offset} | stack],
         inner_context,
         inner_line,
         inner_offset
       ) do
    _ = {rest, acc, context, line, offset}

    horizontal_filter__25(
      inner_rest,
      [],
      [{inner_rest, inner_acc ++ acc, inner_context, inner_line, inner_offset} | stack],
      inner_context,
      inner_line,
      inner_offset
    )
  end

  defp horizontal_filter__27(<<""::binary>>, acc, stack, context, comb__line, comb__offset) do
    horizontal_filter__28("", [] ++ acc, stack, context, comb__line, comb__offset)
  end

  defp horizontal_filter__27(rest, _acc, stack, context, line, offset) do
    [acc | stack] = stack
    horizontal_filter__15(rest, acc, stack, context, line, offset)
  end

  defp horizontal_filter__28(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc

    horizontal_filter__29(
      rest,
      [value: :lists.reverse(user_acc)] ++ acc,
      stack,
      context,
      line,
      offset
    )
  end

  defp horizontal_filter__29(rest, acc, [_, previous_acc | stack], context, line, offset) do
    horizontal_filter__2(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp horizontal_filter__30(_, _, [{rest, context, line, offset} | _] = stack, _, _, _) do
    horizontal_filter__16(rest, [], stack, context, line, offset)
  end

  defp horizontal_filter__31(rest, acc, stack, context, line, offset) do
    horizontal_filter__32(rest, [], [acc | stack], context, line, offset)
  end

  defp horizontal_filter__32(rest, acc, stack, context, line, offset) do
    horizontal_filter__33(rest, [], [acc | stack], context, line, offset)
  end

  defp horizontal_filter__33(
         <<"is", rest::binary>>,
         acc,
         stack,
         context,
         comb__line,
         comb__offset
       ) do
    horizontal_filter__34(rest, ["is"] ++ acc, stack, context, comb__line, comb__offset + 2)
  end

  defp horizontal_filter__33(rest, _acc, stack, context, line, offset) do
    [_, acc | stack] = stack
    horizontal_filter__30(rest, acc, stack, context, line, offset)
  end

  defp horizontal_filter__34(rest, user_acc, [acc | stack], context, line, offset) do
    case (case normalize(rest, user_acc, context, line, offset) do
            {_, _, _} = res ->
              res

            {:error, reason} ->
              {:error, reason}

            {acc, context} ->
              IO.warn(
                "returning a two-element tuple {acc, context} in pre_traverse/post_traverse is deprecated, " <>
                  "please return {rest, acc, context} instead"
              )

              {rest, acc, context}
          end) do
      {rest, user_acc, context} when is_list(user_acc) ->
        horizontal_filter__35(rest, user_acc ++ acc, stack, context, line, offset)

      {:error, reason} ->
        {:error, reason, rest, context, line, offset}
    end
  end

  defp horizontal_filter__35(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc

    horizontal_filter__36(
      rest,
      [operator: :lists.reverse(user_acc)] ++ acc,
      stack,
      context,
      line,
      offset
    )
  end

  defp horizontal_filter__36(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 46 do
    horizontal_filter__37(rest, [] ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp horizontal_filter__36(rest, acc, stack, context, line, offset) do
    horizontal_filter__30(rest, acc, stack, context, line, offset)
  end

  defp horizontal_filter__37(rest, acc, stack, context, line, offset) do
    horizontal_filter__38(rest, [], [acc | stack], context, line, offset)
  end

  defp horizontal_filter__38(
         <<"false", rest::binary>>,
         acc,
         stack,
         context,
         comb__line,
         comb__offset
       ) do
    horizontal_filter__39(rest, [false] ++ acc, stack, context, comb__line, comb__offset + 5)
  end

  defp horizontal_filter__38(
         <<"true", rest::binary>>,
         acc,
         stack,
         context,
         comb__line,
         comb__offset
       ) do
    horizontal_filter__39(rest, [true] ++ acc, stack, context, comb__line, comb__offset + 4)
  end

  defp horizontal_filter__38(rest, _acc, stack, context, line, offset) do
    [acc | stack] = stack
    horizontal_filter__30(rest, acc, stack, context, line, offset)
  end

  defp horizontal_filter__39(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc

    horizontal_filter__40(
      rest,
      [
        value:
          case :lists.reverse(user_acc) do
            [one] -> one
            many -> raise "unwrap_and_tag/3 expected a single token, got: #{inspect(many)}"
          end
      ] ++ acc,
      stack,
      context,
      line,
      offset
    )
  end

  defp horizontal_filter__40(rest, acc, [_, previous_acc | stack], context, line, offset) do
    horizontal_filter__2(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp horizontal_filter__2(rest, acc, _stack, context, line, offset) do
    {:ok, acc, rest, context, line, offset}
  end

  @spec select(binary, keyword) ::
          {:ok, [term], rest, context, line, byte_offset}
          | {:error, reason, rest, context, line, byte_offset}
        when line: {pos_integer, byte_offset},
             byte_offset: non_neg_integer,
             rest: binary,
             reason: String.t(),
             context: map
  defp select(binary, opts \\ []) when is_binary(binary) do
    context = Map.new(Keyword.get(opts, :context, []))
    byte_offset = Keyword.get(opts, :byte_offset, 0)

    line =
      case Keyword.get(opts, :line, 1) do
        {_, _} = line -> line
        line -> {line, byte_offset}
      end

    case select__0(binary, [], [], context, line, byte_offset) do
      {:ok, acc, rest, context, line, offset} ->
        {:ok, :lists.reverse(acc), rest, context, line, offset}

      {:error, _, _, _, _, _} = error ->
        error
    end
  end

  defp select__0(rest, acc, stack, context, line, offset) do
    select__80(rest, [], [{rest, context, line, offset}, acc | stack], context, line, offset)
  end

  defp select__2(rest, acc, stack, context, line, offset) do
    select__3(rest, [], [acc | stack], context, line, offset)
  end

  defp select__3(rest, acc, stack, context, line, offset) do
    select__7(rest, [], [{rest, context, line, offset}, acc | stack], context, line, offset)
  end

  defp select__5(rest, acc, [_, previous_acc | stack], context, line, offset) do
    select__4(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp select__6(_, _, [{rest, context, line, offset} | _] = stack, _, _, _) do
    select__5(rest, [], stack, context, line, offset)
  end

  defp select__7(rest, acc, stack, context, line, offset) do
    select__8(rest, [], [acc | stack], context, line, offset)
  end

  defp select__8(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 95 or (x0 >= 65 and x0 <= 90) or (x0 >= 97 and x0 <= 122) do
    select__9(rest, [x0] ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__8(rest, _acc, stack, context, line, offset) do
    [acc | stack] = stack
    select__6(rest, acc, stack, context, line, offset)
  end

  defp select__9(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 95 or (x0 >= 97 and x0 <= 122) or (x0 >= 65 and x0 <= 90) or
              (x0 >= 48 and x0 <= 57) do
    select__11(rest, [x0] ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__9(rest, acc, stack, context, line, offset) do
    select__10(rest, acc, stack, context, line, offset)
  end

  defp select__11(rest, acc, stack, context, line, offset) do
    select__9(rest, acc, stack, context, line, offset)
  end

  defp select__10(<<x0, x1, _::binary>> = rest, _acc, stack, context, line, offset)
       when x0 === 58 and x1 === 58 do
    [acc | stack] = stack
    select__6(rest, acc, stack, context, line, offset)
  end

  defp select__10(rest, acc, stack, context, line, offset) do
    select__12(rest, acc, stack, context, line, offset)
  end

  defp select__12(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 58 do
    select__13(rest, [] ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__12(rest, _acc, stack, context, line, offset) do
    [acc | stack] = stack
    select__6(rest, acc, stack, context, line, offset)
  end

  defp select__13(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc
    select__14(rest, [alias: :lists.reverse(user_acc)] ++ acc, stack, context, line, offset)
  end

  defp select__14(rest, acc, [_, previous_acc | stack], context, line, offset) do
    select__4(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp select__4(rest, acc, stack, context, line, offset) do
    select__15(rest, [], [acc | stack], context, line, offset)
  end

  defp select__15(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 95 or (x0 >= 65 and x0 <= 90) or (x0 >= 97 and x0 <= 122) do
    select__16(rest, [x0] ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__15(rest, _acc, _stack, context, line, offset) do
    {:error,
     "expected ASCII character equal to \"*\", followed by end of string or ASCII character equal to \"_\" or in the range \"A\" to \"Z\" or in the range \"a\" to \"z\", followed by ASCII character equal to \"_\" or in the range \"a\" to \"z\" or in the range \"A\" to \"Z\" or in the range \"0\" to \"9\", followed by ASCII character equal to \":\", followed by ASCII character equal to \":\", followed by ASCII character equal to \":\" or nothing, followed by ASCII character equal to \"_\" or in the range \"A\" to \"Z\" or in the range \"a\" to \"z\", followed by ASCII character equal to \"_\" or in the range \"a\" to \"z\" or in the range \"A\" to \"Z\" or in the range \"0\" to \"9\", followed by ASCII character equal to \":\", followed by ASCII character equal to \":\", followed by string \"boolean\" or string \"date\" or string \"float\" or string \"integer\" or string \"interval\" or string \"text\" or string \"timestamp\" or nothing, followed by ASCII character equal to \",\", followed by ASCII character equal to \"\\t\" or equal to \" \" or nothing or nothing, followed by ASCII character equal to \"_\" or in the range \"A\" to \"Z\" or in the range \"a\" to \"z\", followed by ASCII character equal to \"_\" or in the range \"a\" to \"z\" or in the range \"A\" to \"Z\" or in the range \"0\" to \"9\", followed by ASCII character equal to \":\", followed by ASCII character equal to \":\", followed by ASCII character equal to \":\" or nothing, followed by ASCII character equal to \"_\" or in the range \"A\" to \"Z\" or in the range \"a\" to \"z\", followed by ASCII character equal to \"_\" or in the range \"a\" to \"z\" or in the range \"A\" to \"Z\" or in the range \"0\" to \"9\", followed by ASCII character equal to \":\", followed by ASCII character equal to \":\", followed by string \"boolean\" or string \"date\" or string \"float\" or string \"integer\" or string \"interval\" or string \"text\" or string \"timestamp\" or nothing, followed by ASCII character equal to \",\", followed by ASCII character equal to \"\\t\" or equal to \" \" or nothing or nothing, followed by end of string",
     rest, context, line, offset}
  end

  defp select__16(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 95 or (x0 >= 97 and x0 <= 122) or (x0 >= 65 and x0 <= 90) or
              (x0 >= 48 and x0 <= 57) do
    select__18(rest, [x0] ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__16(rest, acc, stack, context, line, offset) do
    select__17(rest, acc, stack, context, line, offset)
  end

  defp select__18(rest, acc, stack, context, line, offset) do
    select__16(rest, acc, stack, context, line, offset)
  end

  defp select__17(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc
    select__19(rest, [name: :lists.reverse(user_acc)] ++ acc, stack, context, line, offset)
  end

  defp select__19(rest, acc, stack, context, line, offset) do
    select__23(rest, [], [{rest, context, line, offset}, acc | stack], context, line, offset)
  end

  defp select__21(rest, acc, [_, previous_acc | stack], context, line, offset) do
    select__20(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp select__22(_, _, [{rest, context, line, offset} | _] = stack, _, _, _) do
    select__21(rest, [], stack, context, line, offset)
  end

  defp select__23(rest, acc, stack, context, line, offset) do
    select__24(rest, [], [acc | stack], context, line, offset)
  end

  defp select__24(rest, acc, stack, context, line, offset) do
    select__25(rest, [], [acc | stack], context, line, offset)
  end

  defp select__25(<<x0, x1, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 58 and x1 === 58 do
    select__26(rest, [] ++ acc, stack, context, comb__line, comb__offset + 2)
  end

  defp select__25(rest, _acc, stack, context, line, offset) do
    [_, acc | stack] = stack
    select__22(rest, acc, stack, context, line, offset)
  end

  defp select__26(<<"boolean", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__27(rest, ["boolean"] ++ acc, stack, context, comb__line, comb__offset + 7)
  end

  defp select__26(<<"date", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__27(rest, ["date"] ++ acc, stack, context, comb__line, comb__offset + 4)
  end

  defp select__26(<<"float", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__27(rest, ["float"] ++ acc, stack, context, comb__line, comb__offset + 5)
  end

  defp select__26(<<"integer", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__27(rest, ["integer"] ++ acc, stack, context, comb__line, comb__offset + 7)
  end

  defp select__26(<<"interval", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__27(rest, ["interval"] ++ acc, stack, context, comb__line, comb__offset + 8)
  end

  defp select__26(<<"text", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__27(rest, ["text"] ++ acc, stack, context, comb__line, comb__offset + 4)
  end

  defp select__26(<<"timestamp", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__27(rest, ["timestamp"] ++ acc, stack, context, comb__line, comb__offset + 9)
  end

  defp select__26(rest, _acc, stack, context, line, offset) do
    [_, acc | stack] = stack
    select__22(rest, acc, stack, context, line, offset)
  end

  defp select__27(rest, user_acc, [acc | stack], context, line, offset) do
    case (case normalize(rest, user_acc, context, line, offset) do
            {_, _, _} = res ->
              res

            {:error, reason} ->
              {:error, reason}

            {acc, context} ->
              IO.warn(
                "returning a two-element tuple {acc, context} in pre_traverse/post_traverse is deprecated, " <>
                  "please return {rest, acc, context} instead"
              )

              {rest, acc, context}
          end) do
      {rest, user_acc, context} when is_list(user_acc) ->
        select__28(rest, user_acc ++ acc, stack, context, line, offset)

      {:error, reason} ->
        {:error, reason, rest, context, line, offset}
    end
  end

  defp select__28(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc
    select__29(rest, [cast: :lists.reverse(user_acc)] ++ acc, stack, context, line, offset)
  end

  defp select__29(rest, acc, [_, previous_acc | stack], context, line, offset) do
    select__20(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp select__20(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc
    select__30(rest, [:lists.reverse(user_acc)] ++ acc, stack, context, line, offset)
  end

  defp select__30(rest, acc, stack, context, line, offset) do
    select__34(rest, [], [{rest, context, line, offset}, acc | stack], context, line, offset)
  end

  defp select__32(rest, acc, [_, previous_acc | stack], context, line, offset) do
    select__31(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp select__33(_, _, [{rest, context, line, offset} | _] = stack, _, _, _) do
    select__32(rest, [], stack, context, line, offset)
  end

  defp select__34(rest, acc, stack, context, line, offset) do
    select__35(rest, [], [acc | stack], context, line, offset)
  end

  defp select__35(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 44 do
    select__36(rest, acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__35(rest, _acc, stack, context, line, offset) do
    [acc | stack] = stack
    select__33(rest, acc, stack, context, line, offset)
  end

  defp select__36(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 9 or x0 === 32 do
    select__37(rest, acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__36(<<rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__37(rest, acc, stack, context, comb__line, comb__offset)
  end

  defp select__37(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc
    select__38(rest, [] ++ acc, stack, context, line, offset)
  end

  defp select__38(rest, acc, [_, previous_acc | stack], context, line, offset) do
    select__31(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp select__31(rest, acc, stack, context, line, offset) do
    select__40(rest, [], [{rest, acc, context, line, offset} | stack], context, line, offset)
  end

  defp select__40(rest, acc, stack, context, line, offset) do
    select__41(rest, [], [acc | stack], context, line, offset)
  end

  defp select__41(rest, acc, stack, context, line, offset) do
    select__45(rest, [], [{rest, context, line, offset}, acc | stack], context, line, offset)
  end

  defp select__43(rest, acc, [_, previous_acc | stack], context, line, offset) do
    select__42(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp select__44(_, _, [{rest, context, line, offset} | _] = stack, _, _, _) do
    select__43(rest, [], stack, context, line, offset)
  end

  defp select__45(rest, acc, stack, context, line, offset) do
    select__46(rest, [], [acc | stack], context, line, offset)
  end

  defp select__46(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 95 or (x0 >= 65 and x0 <= 90) or (x0 >= 97 and x0 <= 122) do
    select__47(rest, [x0] ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__46(rest, _acc, stack, context, line, offset) do
    [acc | stack] = stack
    select__44(rest, acc, stack, context, line, offset)
  end

  defp select__47(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 95 or (x0 >= 97 and x0 <= 122) or (x0 >= 65 and x0 <= 90) or
              (x0 >= 48 and x0 <= 57) do
    select__49(rest, [x0] ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__47(rest, acc, stack, context, line, offset) do
    select__48(rest, acc, stack, context, line, offset)
  end

  defp select__49(rest, acc, stack, context, line, offset) do
    select__47(rest, acc, stack, context, line, offset)
  end

  defp select__48(<<x0, x1, _::binary>> = rest, _acc, stack, context, line, offset)
       when x0 === 58 and x1 === 58 do
    [acc | stack] = stack
    select__44(rest, acc, stack, context, line, offset)
  end

  defp select__48(rest, acc, stack, context, line, offset) do
    select__50(rest, acc, stack, context, line, offset)
  end

  defp select__50(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 58 do
    select__51(rest, [] ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__50(rest, _acc, stack, context, line, offset) do
    [acc | stack] = stack
    select__44(rest, acc, stack, context, line, offset)
  end

  defp select__51(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc
    select__52(rest, [alias: :lists.reverse(user_acc)] ++ acc, stack, context, line, offset)
  end

  defp select__52(rest, acc, [_, previous_acc | stack], context, line, offset) do
    select__42(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp select__42(rest, acc, stack, context, line, offset) do
    select__53(rest, [], [acc | stack], context, line, offset)
  end

  defp select__53(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 95 or (x0 >= 65 and x0 <= 90) or (x0 >= 97 and x0 <= 122) do
    select__54(rest, [x0] ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__53(rest, _acc, stack, context, line, offset) do
    [_, acc | stack] = stack
    select__39(rest, acc, stack, context, line, offset)
  end

  defp select__54(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 95 or (x0 >= 97 and x0 <= 122) or (x0 >= 65 and x0 <= 90) or
              (x0 >= 48 and x0 <= 57) do
    select__56(rest, [x0] ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__54(rest, acc, stack, context, line, offset) do
    select__55(rest, acc, stack, context, line, offset)
  end

  defp select__56(rest, acc, stack, context, line, offset) do
    select__54(rest, acc, stack, context, line, offset)
  end

  defp select__55(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc
    select__57(rest, [name: :lists.reverse(user_acc)] ++ acc, stack, context, line, offset)
  end

  defp select__57(rest, acc, stack, context, line, offset) do
    select__61(rest, [], [{rest, context, line, offset}, acc | stack], context, line, offset)
  end

  defp select__59(rest, acc, [_, previous_acc | stack], context, line, offset) do
    select__58(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp select__60(_, _, [{rest, context, line, offset} | _] = stack, _, _, _) do
    select__59(rest, [], stack, context, line, offset)
  end

  defp select__61(rest, acc, stack, context, line, offset) do
    select__62(rest, [], [acc | stack], context, line, offset)
  end

  defp select__62(rest, acc, stack, context, line, offset) do
    select__63(rest, [], [acc | stack], context, line, offset)
  end

  defp select__63(<<x0, x1, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 58 and x1 === 58 do
    select__64(rest, [] ++ acc, stack, context, comb__line, comb__offset + 2)
  end

  defp select__63(rest, _acc, stack, context, line, offset) do
    [_, acc | stack] = stack
    select__60(rest, acc, stack, context, line, offset)
  end

  defp select__64(<<"boolean", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__65(rest, ["boolean"] ++ acc, stack, context, comb__line, comb__offset + 7)
  end

  defp select__64(<<"date", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__65(rest, ["date"] ++ acc, stack, context, comb__line, comb__offset + 4)
  end

  defp select__64(<<"float", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__65(rest, ["float"] ++ acc, stack, context, comb__line, comb__offset + 5)
  end

  defp select__64(<<"integer", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__65(rest, ["integer"] ++ acc, stack, context, comb__line, comb__offset + 7)
  end

  defp select__64(<<"interval", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__65(rest, ["interval"] ++ acc, stack, context, comb__line, comb__offset + 8)
  end

  defp select__64(<<"text", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__65(rest, ["text"] ++ acc, stack, context, comb__line, comb__offset + 4)
  end

  defp select__64(<<"timestamp", rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__65(rest, ["timestamp"] ++ acc, stack, context, comb__line, comb__offset + 9)
  end

  defp select__64(rest, _acc, stack, context, line, offset) do
    [_, acc | stack] = stack
    select__60(rest, acc, stack, context, line, offset)
  end

  defp select__65(rest, user_acc, [acc | stack], context, line, offset) do
    case (case normalize(rest, user_acc, context, line, offset) do
            {_, _, _} = res ->
              res

            {:error, reason} ->
              {:error, reason}

            {acc, context} ->
              IO.warn(
                "returning a two-element tuple {acc, context} in pre_traverse/post_traverse is deprecated, " <>
                  "please return {rest, acc, context} instead"
              )

              {rest, acc, context}
          end) do
      {rest, user_acc, context} when is_list(user_acc) ->
        select__66(rest, user_acc ++ acc, stack, context, line, offset)

      {:error, reason} ->
        {:error, reason, rest, context, line, offset}
    end
  end

  defp select__66(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc
    select__67(rest, [cast: :lists.reverse(user_acc)] ++ acc, stack, context, line, offset)
  end

  defp select__67(rest, acc, [_, previous_acc | stack], context, line, offset) do
    select__58(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp select__58(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc
    select__68(rest, [:lists.reverse(user_acc)] ++ acc, stack, context, line, offset)
  end

  defp select__68(rest, acc, stack, context, line, offset) do
    select__72(rest, [], [{rest, context, line, offset}, acc | stack], context, line, offset)
  end

  defp select__70(rest, acc, [_, previous_acc | stack], context, line, offset) do
    select__69(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp select__71(_, _, [{rest, context, line, offset} | _] = stack, _, _, _) do
    select__70(rest, [], stack, context, line, offset)
  end

  defp select__72(rest, acc, stack, context, line, offset) do
    select__73(rest, [], [acc | stack], context, line, offset)
  end

  defp select__73(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 44 do
    select__74(rest, acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__73(rest, _acc, stack, context, line, offset) do
    [acc | stack] = stack
    select__71(rest, acc, stack, context, line, offset)
  end

  defp select__74(<<x0, rest::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 9 or x0 === 32 do
    select__75(rest, acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__74(<<rest::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__75(rest, acc, stack, context, comb__line, comb__offset)
  end

  defp select__75(rest, user_acc, [acc | stack], context, line, offset) do
    _ = user_acc
    select__76(rest, [] ++ acc, stack, context, line, offset)
  end

  defp select__76(rest, acc, [_, previous_acc | stack], context, line, offset) do
    select__69(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp select__39(_, _, [{rest, acc, context, line, offset} | stack], _, _, _) do
    select__77(rest, acc, stack, context, line, offset)
  end

  defp select__69(
         inner_rest,
         inner_acc,
         [{rest, acc, context, line, offset} | stack],
         inner_context,
         inner_line,
         inner_offset
       ) do
    _ = {rest, acc, context, line, offset}

    select__40(
      inner_rest,
      [],
      [{inner_rest, inner_acc ++ acc, inner_context, inner_line, inner_offset} | stack],
      inner_context,
      inner_line,
      inner_offset
    )
  end

  defp select__77(<<""::binary>>, acc, stack, context, comb__line, comb__offset) do
    select__78("", [] ++ acc, stack, context, comb__line, comb__offset)
  end

  defp select__77(rest, _acc, _stack, context, line, offset) do
    {:error,
     "expected ASCII character equal to \"*\", followed by end of string or ASCII character equal to \"_\" or in the range \"A\" to \"Z\" or in the range \"a\" to \"z\", followed by ASCII character equal to \"_\" or in the range \"a\" to \"z\" or in the range \"A\" to \"Z\" or in the range \"0\" to \"9\", followed by ASCII character equal to \":\", followed by ASCII character equal to \":\", followed by ASCII character equal to \":\" or nothing, followed by ASCII character equal to \"_\" or in the range \"A\" to \"Z\" or in the range \"a\" to \"z\", followed by ASCII character equal to \"_\" or in the range \"a\" to \"z\" or in the range \"A\" to \"Z\" or in the range \"0\" to \"9\", followed by ASCII character equal to \":\", followed by ASCII character equal to \":\", followed by string \"boolean\" or string \"date\" or string \"float\" or string \"integer\" or string \"interval\" or string \"text\" or string \"timestamp\" or nothing, followed by ASCII character equal to \",\", followed by ASCII character equal to \"\\t\" or equal to \" \" or nothing or nothing, followed by ASCII character equal to \"_\" or in the range \"A\" to \"Z\" or in the range \"a\" to \"z\", followed by ASCII character equal to \"_\" or in the range \"a\" to \"z\" or in the range \"A\" to \"Z\" or in the range \"0\" to \"9\", followed by ASCII character equal to \":\", followed by ASCII character equal to \":\", followed by ASCII character equal to \":\" or nothing, followed by ASCII character equal to \"_\" or in the range \"A\" to \"Z\" or in the range \"a\" to \"z\", followed by ASCII character equal to \"_\" or in the range \"a\" to \"z\" or in the range \"A\" to \"Z\" or in the range \"0\" to \"9\", followed by ASCII character equal to \":\", followed by ASCII character equal to \":\", followed by string \"boolean\" or string \"date\" or string \"float\" or string \"integer\" or string \"interval\" or string \"text\" or string \"timestamp\" or nothing, followed by ASCII character equal to \",\", followed by ASCII character equal to \"\\t\" or equal to \" \" or nothing or nothing, followed by end of string",
     rest, context, line, offset}
  end

  defp select__78(rest, acc, [_, previous_acc | stack], context, line, offset) do
    select__1(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp select__79(_, _, [{rest, context, line, offset} | _] = stack, _, _, _) do
    select__2(rest, [], stack, context, line, offset)
  end

  defp select__80(<<x0, ""::binary>>, acc, stack, context, comb__line, comb__offset)
       when x0 === 42 do
    select__81("", [default: [x0]] ++ acc, stack, context, comb__line, comb__offset + 1)
  end

  defp select__80(rest, acc, stack, context, line, offset) do
    select__79(rest, acc, stack, context, line, offset)
  end

  defp select__81(rest, acc, [_, previous_acc | stack], context, line, offset) do
    select__1(rest, acc ++ previous_acc, stack, context, line, offset)
  end

  defp select__1(rest, acc, _stack, context, line, offset) do
    {:ok, acc, rest, context, line, offset}
  end

  # ===========================================================================
  # Regular (pass-through) code: the `normalize/5` post_traverse callback (called
  # by the generated `select`/`horizontal_filter` parsers), the public wrappers,
  # and the whole request pipeline.
  # ===========================================================================

  # `normalize/5` is the `post_traverse` callback for the legacy
  # `select`/`horizontal_filter` grammars: it reverses the matched operator/cast
  # token into a charlist. The `case` over `casting_type` is degenerate at
  # runtime (it always takes the binary branch) but keeps the inferred return
  # type a union of the three shapes nimble_parsec's generated dispatch matches
  # on, so the generated file stays clean under `--warnings-as-errors`.
  defp normalize(rest, [casting_type], %{} = context, {_line, _line_offset}, _byte_offset) do
    case context do
      %{__pt__: :error} ->
        {:error, "unreachable"}

      %{__pt__: :legacy} ->
        {[casting_type], context}

      _ ->
        {rest, casting_type |> String.reverse() |> String.to_charlist(), context}
    end
  end

  @doc """
  Parse the given `select` query string

  ## Examples

      iex> parse_select("*")
      {:ok, [default: ~c"*"]}
      iex> parse_select("first_name,age")
      {:ok, [[name: ~c"first_name"], [name: ~c"age"]]}
      iex> parse_select("fullName:full_name,birthDate:birth_date")
      {:ok, [[alias: ~c"fullName", name: ~c"full_name"], [alias: ~c"birthDate", name: ~c"birth_date"]]}
      iex> parse_select("uno:first::text, dos:second, third, forth::text")
      {:ok, [[alias: ~c"uno", name: ~c"first", cast: ~c"text"], [alias: ~c"dos", name: ~c"second"], [name: ~c"third"], [name: ~c"forth", cast: ~c"text"]]}
  """
  @spec parse_select(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def parse_select(select) do
    case select(select) do
      {:ok, result, _rest = "", _context, _line, _byte_offset} ->
        {:ok, result}

      {:error, reason, _rest, _contact, _line, _byte_offset} ->
        {:error, reason}
    end
  end

  @doc """
  Parse the given horizontal filters (rows)

  You can filter result rows by filtering conditions on columns.

  ## Examples

      iex> parse_filters(%{age: "lt.13"})
      {:ok, [{:age, [negation?: false, operator: ~c"<", value: ~c"13"]}]}
      iex> parse_filters(%{age: "gt.13"})
      {:ok, [{:age, [negation?: false, operator: ~c">", value: ~c"13"]}]}
      iex> parse_filters(%{age: "gte.13"})
      {:ok, [{:age, [negation?: false, operator: ~c">=", value: ~c"13"]}]}
      iex> parse_filters(%{age: "not.gte.13"})
      {:ok, [{:age, [negation?: true, operator: ~c">=", value: ~c"13"]}]}
  """
  def parse_filters(params) when is_map(params) do
    result =
      Enum.reduce_while(params, [], fn {field, filter}, acc ->
        case horizontal_filter(filter) do
          {:ok, parsed, "", %{}, _, _} ->
            parsed_filter = Keyword.put_new(parsed, :negation?, false)
            {:cont, [{field, parsed_filter} | acc]}

          _ ->
            {:halt, :bad_request}
        end
      end)

    case result do
      :bad_request -> {:error, :bad_request}
      result -> {:ok, result}
    end
  end

  defguardp order_direction(direction) when direction in ["asc", "desc"]
  defguardp nulls_order(nulls) when nulls in ["nullsfirst", "nullslast"]

  @doc """
  Parses the given order clause

  ## Examples

      iex> parse_order("")
      {:ok, []}
      iex> parse_order("age")
      {:ok, [{"age", "asc", "nulls last"}]}
      iex> parse_order("age.desc,height.asc")
      {:ok, [{"height", "asc", "nulls last"}, {"age", "desc", "nulls first"}]}
      iex> parse_order("age.nullsfirst")
      {:ok, [{"age", "asc", "nulls first"}]}
      iex> parse_order("age.desc.nullslast")
      {:ok, [{"age", "desc", "nulls last"}]}
      iex> parse_order("age.left,height.asc")
      {:error, :bad_request}
  """
  def parse_order(""), do: {:ok, []}

  def parse_order(order) do
    result =
      order
      |> String.split(",")
      |> Enum.reduce_while([], fn line, acc ->
        case String.split(line, ".", parts: 3) do
          [field, direction, nulls] when order_direction(direction) and nulls_order(nulls) ->
            {:cont, [{field, direction, transform_nulls(nulls)} | acc]}

          [field, direction] when order_direction(direction) ->
            {:cont, [{field, direction, default_null_option(direction)} | acc]}

          [field, nulls] when nulls_order(nulls) ->
            {:cont, [{field, "asc", transform_nulls(nulls)} | acc]}

          [field] ->
            {:cont, [{field, "asc", "nulls last"} | acc]}

          _ ->
            {:halt, :bad_request}
        end
      end)

    case result do
      :bad_request -> {:error, :bad_request}
      result -> {:ok, result}
    end
  end

  defp default_null_option("desc"), do: "nulls first"
  defp default_null_option("asc"), do: "nulls last"

  defp transform_nulls("nullsfirst"), do: "nulls first"
  defp transform_nulls("nullslast"), do: "nulls last"

  @doc """
  Parse the given limit

  ## Examples

      iex> parse_limit(10)
      {:ok, 10}
      iex> parse_limit("10")
      {:ok, 10}
      iex> parse_limit("10.1")
      {:error, :bad_request}
      iex> parse_limit("0")
      {:error, :bad_request}
      iex> parse_limit(%{})
      {:error, :bad_request}
  """
  def parse_limit(limit) when is_integer(limit) and limit > 0, do: {:ok, limit}

  def parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, ""} when limit > 0 -> {:ok, limit}
      _ -> {:error, :bad_request}
    end
  end

  def parse_limit(_), do: {:error, :bad_request}

  @doc """
  Parses request body before querying the database
  """
  def parse_request_body(params) when is_list(params) or is_map(params) do
    params
    |> List.wrap()
    |> prepare_params_for_insert()
  end

  defp prepare_params_for_insert([h | _t] = params) do
    keys = Map.keys(h)

    result =
      Enum.reduce_while(params, [], fn p, acc ->
        case prepare_row_for_insert(keys, p) do
          {values, map} when map_size(map) == 0 ->
            {:cont, [Enum.reverse(values) | acc]}

          _ ->
            {:halt, :mismatch}
        end
      end)

    case result do
      :mismatch ->
        {:error, :mismatch}

      values ->
        {:ok, %{keys: keys, values: values}}
    end
  end

  defp prepare_row_for_insert(keys, row) do
    Enum.reduce_while(keys, {[], row}, fn key, {values, map} ->
      case Map.pop(map, key) do
        {nil, _} ->
          {:halt, :mismatch}

        {v, updated_map} ->
          {:cont, {[prepare_value_for_insert(v) | values], updated_map}}
      end
    end)
  end

  defp prepare_value_for_insert(value) when is_binary(value), do: "'#{value}'"
  defp prepare_value_for_insert(value), do: value

  # ==========================================================================
  # Request pipeline parsing (PostgREST-shaped)
  #
  # The functions below are a separate, structured parsing path used by the
  # request pipeline (`Bier.QueryExecutor`). They are independent from the
  # legacy `parse_select/1`, `parse_filters/1`, `parse_order/1` helpers above
  # (kept for backwards compatibility and their doctests). They take the raw
  # query string of a request and produce an AST of selects/filters/order that
  # `Bier.QueryExecutor` turns into one parameterized SQL statement.
  # ==========================================================================

  @reserved ~w(select order limit offset on_conflict columns and or not)

  # ---- leaf-grammar backend ------------------------------------------------
  #
  # The leaf grammars below (`parse_json_path/1`, `split_op_value/1`,
  # `parse_filter_expr/2`, `parse_order_term/1`, `parse_scalar_select/1`,
  # `valid_identifier?/1`, `embed?/1`, `aggregate?/1`) are served by the
  # `nimble_parsec`-based implementation in `Bier.QueryParser.Nimble`. These
  # functions delegate directly to that module's compiled combinators; see
  # `bench/REPORT.md` for the assessment that motivated this.

  @doc """
  Parse a full request query string into a structured query plan.

  Returns `{:ok, plan}` where `plan` is a map with keys `:select`, `:filters`,
  `:order`, `:limit`, `:offset`, or `{:error, reason}`.

  `select`/`order` items and column filters are returned as data; the executor
  resolves them against the relation's columns and renders SQL.
  """
  @spec parse_request(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_request(query_string) when is_binary(query_string) do
    params = decode_query(query_string)

    with {:ok, select} <- pg_select(params),
         {:ok, order} <- pg_order(params["order"]),
         {:ok, embed_orders} <- pg_embed_orders(params),
         {:ok, limit} <- pg_limit(params["limit"]),
         {:ok, offset} <- pg_offset(params["offset"]),
         {:ok, embed_limits} <- pg_embed_paged(params, "limit", &pg_limit/1),
         {:ok, embed_offsets} <- pg_embed_paged(params, "offset", &pg_offset/1),
         {:ok, columns} <- pg_columns(params),
         {:ok, on_conflict} <- pg_on_conflict(params),
         {:ok, {filters, embed_filters}} <- pg_filters(params) do
      {:ok,
       %{
         select: select,
         filters: filters,
         embed_filters: embed_filters,
         order: order,
         embed_orders: embed_orders,
         limit: limit,
         offset: offset,
         embed_limits: embed_limits,
         embed_offsets: embed_offsets,
         columns: columns,
         on_conflict: on_conflict,
         # The presence of `limit`/`offset` query params is needed by PUT (which
         # rejects them); record it separately since the values may be nil.
         has_limit: Map.has_key?(params, "limit"),
         has_offset: Map.has_key?(params, "offset")
       }}
    end
  end

  # ---- columns / on_conflict (mutation write params) -----------------------

  # `?columns=a,b,c` selects which JSON keys become target columns for a write
  # (extra keys in the payload are ignored). A *present but blank* `columns=`
  # is a PGRST100 parse error; an absent param means "derive columns from the
  # payload keys" (signalled by `nil`).
  defp pg_columns(params) do
    case Map.get(params, "columns") do
      nil ->
        {:ok, nil}

      "" ->
        {:error, :blank_columns}

      raw ->
        cols =
          raw
          |> split_top_commas()
          |> Enum.map(&String.trim/1)

        if cols == [] or Enum.any?(cols, &(&1 == "")) do
          {:error, :blank_columns}
        else
          {:ok, cols}
        end
    end
  end

  # `?on_conflict=a,b` names the columns of the unique/exclusion constraint to
  # use as the upsert conflict target. Absent => nil (use the PK).
  defp pg_on_conflict(params) do
    case Map.get(params, "on_conflict") do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      raw ->
        cols =
          raw
          |> split_top_commas()
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, cols}
    end
  end

  # Decode a query string into an ordered list-aware map. We keep duplicate keys
  # by collecting them; `and`/`or` may repeat. Values are URL-decoded with `+`
  # mapped to a space per application/x-www-form-urlencoded rules.
  defp decode_query(""), do: %{}

  defp decode_query(qs) do
    qs
    |> String.split("&")
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> Map.update(acc, url_decode(k), [url_decode(v)], &(&1 ++ [url_decode(v)]))
        [k] -> Map.put_new(acc, url_decode(k), [""])
      end
    end)
    |> Map.new(fn
      {k, [single]} -> {k, single}
      {k, list} -> {k, list}
    end)
  end

  defp url_decode(str) do
    str |> String.replace("+", " ") |> URI.decode()
  end

  # ---- select --------------------------------------------------------------

  defp pg_select(params) do
    case Map.get(params, "select") do
      nil ->
        {:ok, [:star]}

      "" ->
        {:ok, [:star]}

      "*" ->
        {:ok, [:star]}

      sel ->
        # A select-parse failure is a 400 PGRST100 with PostgREST's parser-error
        # envelope referencing the *whole* select parameter and the 1-based
        # column of the offending token (cases 1111/1180). We surface a rich
        # error tagged with the original select string so the controller can
        # render the `failed to parse select parameter (...)` message.
        case parse_select_tree(sel) do
          {:ok, nodes} -> {:ok, nodes}
          {:error, {:select_parse, _node}} -> {:error, select_parse_error(sel)}
          {:error, other} -> {:error, other}
        end
    end
  end

  # Build the PostgREST select parse-error tuple `{:select_parse, select, detail,
  # column}`. We locate the first malformed json-path token within the select
  # string to compute the column and detail (`data->>--34` => column 9,
  # `unexpected "-" expecting digit`).
  defp select_parse_error(sel) do
    {detail, column} = locate_select_error(sel)
    {:select_parse, sel, detail, column}
  end

  # Find the offending token in a select string carrying a json path. We look for
  # the first `->`/`->>` arrow followed by an invalid key. After an arrow the
  # parser expects an integer index (optional single leading `-`) or a key; a
  # second `-` (e.g. `->>--34`) is "unexpected '-' expecting digit".
  defp locate_select_error(sel) do
    case scan_arrow_double_dash(sel, 0) do
      {:ok, second_dash_byte} ->
        # The match operates on ASCII bytes (`-`/`>`), so the byte offset of the
        # second dash equals its 0-based char position; +1 makes it 1-based.
        {"unexpected \"-\" expecting digit", second_dash_byte + 1}

      :error ->
        # Fallback: point just past the last valid prefix.
        {"unexpected end of input", String.length(sel) + 1}
    end
  end

  # Non-regex twin of the `->>?(-)(-)` pattern: scan for the leftmost `->`/`->>` arrow
  # immediately followed by `--`, returning the byte offset of the *second* dash
  # (the regex's group-2 index). Mirrors the regex's greedy `>?` (prefer `->>`,
  # fall back to `->`) and left-to-right scan.
  defp scan_arrow_double_dash(sel, from) do
    case :binary.match(sel, "->", scope: {from, byte_size(sel) - from}) do
      :nomatch ->
        :error

      {pos, _len} ->
        rest = binary_part(sel, pos, byte_size(sel) - pos)

        cond do
          # `->>--`: arrow is `->>`, then `--`; second dash is at pos + 4.
          match?("->>--" <> _, rest) -> {:ok, pos + 4}
          # `->--`: arrow is `->`, then `--`; second dash is at pos + 3.
          match?("->--" <> _, rest) -> {:ok, pos + 3}
          # No double-dash here; resume scanning just past this `->`.
          true -> scan_arrow_double_dash(sel, pos + 2)
        end
    end
  end

  # Parse a (possibly nested) select list into a list of nodes. A node is one of:
  #
  #   %{kind: :field, ...}      -- scalar column / json-path / cast
  #   %{kind: :star}            -- `*`
  #   %{kind: :agg, ...}        -- aggregate (col.fn() or count())
  #   %{kind: :embed, ...}      -- related resource `rel(...)` / `rel!hint(...)`
  #                                 / spread `...rel(...)`
  def parse_select_tree(sel) do
    sel
    |> split_top_commas()
    |> Enum.reduce_while([], fn raw, acc ->
      case parse_select_node(String.trim(raw)) do
        {:ok, node} -> {:cont, [node | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp parse_select_node(field) do
    cond do
      field == "" ->
        {:error, {:select_parse, field}}

      field == "*" ->
        {:ok, %{kind: :star}}

      String.starts_with?(field, "...") ->
        parse_embed(String.trim_leading(field, "."), true)

      aggregate?(field) ->
        parse_aggregate(field)

      embed?(field) ->
        parse_embed(field, false)

      true ->
        parse_scalar_select(field)
    end
  end

  # A field references an embedding when it has a `(` at the top level that is
  # not preceded by a `.` aggregate marker, i.e. `name(...)` / `alias:name(...)`
  # / `name!hint(...)`.
  defp embed?(field), do: Nimble.embed?(field)

  # Aggregate forms: `count()`, `col.sum()`, `alias:col.sum()::cast`.
  #
  # A bare `name()` (no `col.` prefix) is only an aggregate when `name` is one of
  # the known aggregate functions; otherwise `name()` is an empty-projection
  # embed (e.g. `child_entities()` used for null filtering). A `col.fn()` form is
  # always an aggregate.
  defp aggregate?(field), do: Nimble.aggregate?(field)

  defp parse_aggregate(field) do
    {out_alias, rest} = split_alias(field)

    {cast, rest} = Nimble.peel_agg_cast(rest)

    case Nimble.parse_agg_call(rest) do
      {:ok, nil, fun} ->
        {:ok, %{kind: :agg, column: nil, fun: fun, alias: out_alias, cast: cast}}

      {:ok, col, fun} ->
        if valid_identifier?(col),
          do: {:ok, %{kind: :agg, column: col, fun: fun, alias: out_alias, cast: cast}},
          else: {:error, {:select_parse, field}}

      :error ->
        {:error, {:select_parse, field}}
    end
  end

  # Parse an embedding term: `[alias:]relation[!hint...][!inner|!left](sub-select)`
  defp parse_embed(field, spread?) do
    {emb_alias, rest} = split_alias(field)

    case Nimble.parse_embed_parts(rest) do
      {:ok, head, inner} ->
        {target, hints} = parse_embed_head(head)

        {join_type, hints} = extract_join_type(hints)

        with {:ok, children} <- parse_inner_select(inner) do
          {:ok,
           %{
             kind: :embed,
             target: target,
             alias: emb_alias,
             spread: spread?,
             hint: List.first(hints),
             join: join_type,
             empty: String.trim(inner) == "",
             select: children
           }}
        end

      _ ->
        {:error, {:select_parse, field}}
    end
  end

  defp parse_inner_select(""), do: {:ok, [:star]}

  defp parse_inner_select(inner) do
    case parse_select_tree(inner) do
      {:ok, list} -> {:ok, list}
      other -> other
    end
  end

  # `relation!a!b` -> {"relation", ["a", "b"]}
  defp parse_embed_head(head) do
    case String.split(head, "!") do
      [target | hints] -> {String.trim(target), Enum.map(hints, &String.trim/1)}
    end
  end

  # Pull `inner`/`left` join markers out of the hint list.
  defp extract_join_type(hints) do
    cond do
      "inner" in hints -> {:inner, hints -- ["inner"]}
      "left" in hints -> {:left, hints -- ["left"]}
      true -> {nil, hints}
    end
  end

  # Split a leading `alias:` (not a `::` cast) off the front of a term.
  defp split_alias(field), do: Nimble.split_alias(field)

  defp parse_scalar_select(field), do: Nimble.parse_scalar_select(field)

  # ---- order ---------------------------------------------------------------

  defp pg_order(nil), do: {:ok, []}
  defp pg_order(""), do: {:ok, []}

  defp pg_order(order) when is_list(order) do
    # Duplicate `order=` params: PostgREST uses the last occurrence.
    pg_order(List.last(order))
  end

  defp pg_order(order) do
    order
    |> split_top_commas()
    |> Enum.reduce_while([], fn raw, acc ->
      case parse_order_term(String.trim(raw)) do
        {:ok, term} -> {:cont, [term | acc]}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:error, _} = e -> e
      list -> {:ok, Enum.reverse(list)}
    end
  end

  # Embed-targeted order params: `<rel>.order=...`, `<rel>.<rel2>.order=...`.
  # Returns a map of embed-path (list) => order terms list. Validated like the
  # top-level order; bad syntax surfaces the same PGRST100 error.
  defp pg_embed_orders(params) do
    params
    |> Enum.filter(fn {k, _v} -> String.ends_with?(k, ".order") end)
    |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
      path =
        k
        |> String.replace_suffix(".order", "")
        |> String.split(".")

      case pg_order(v) do
        {:ok, terms} -> {:cont, {:ok, Map.put(acc, path, terms)}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  # Embed-targeted `limit`/`offset` params: `<rel>.limit=N`, `<rel>.<rel2>.offset=N`.
  # Returns a map of embed-path (list) => integer (or nil). `kind` is "limit" or
  # "offset"; `parse_fun` is the matching top-level parser so validation (and the
  # negative-limit / negative-offset semantics) stay consistent.
  defp pg_embed_paged(params, kind, parse_fun) do
    suffix = "." <> kind

    params
    |> Enum.filter(fn {k, _v} -> String.ends_with?(k, suffix) and k != kind end)
    |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
      path = k |> String.replace_suffix(suffix, "") |> String.split(".")
      value = if is_list(v), do: List.last(v), else: v

      case parse_fun.(value) do
        {:ok, n} -> {:cont, {:ok, Map.put(acc, path, n)}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  # Order term, one of:
  #
  #   * column order:  `<col>[->json][.asc|.desc][.nullsfirst|.nullslast]`
  #   * related order: `<rel>(<col>[->json])[.asc|.desc][.nulls...]` — orders by a
  #     column of a to-one related (embedded) resource.
  defp parse_order_term(term), do: Nimble.parse_order_term(term)

  # PostgREST renders a precise parser error for bad order syntax. We reproduce
  # the common case (an unexpected trailing token after a valid prefix) used by
  # the conformance suite; other malformed terms fall back to the same envelope.
  @doc false
  def order_error(term) do
    count = leading_valid_order_length(term)
    bad_rest = String.slice(term, count..-1//1)

    detail =
      case bad_rest do
        "" -> "unexpected end of input"
        <<c::utf8, _::binary>> -> "unexpected '#{<<c::utf8>>}' expecting \",\" or end of input"
      end

    # column is the 1-based char position (within the order string) of the
    # unexpected token, i.e. just past the longest valid prefix. For the
    # conformance case `id.asc.nullslasttt` PostgREST parses `id.asc.nullslast`
    # (16 chars) then reports the trailing `t` at column 17.
    column = count + 1

    {:error, {:order_parse, term, detail, column}}
  end

  @order_keywords ~w(asc desc nullsfirst nullslast)

  # Number of chars of `term` that parse as a valid `col[.dir][.nulls]` prefix,
  # greedily consuming keyword prefixes within a malformed final token (so
  # `nullslasttt` consumes `nullslast`). Used to compute the error column.
  defp leading_valid_order_length(term) do
    parts = term |> String.split(".") |> Enum.with_index()

    {len, _expect} =
      Enum.reduce_while(parts, {0, :col}, fn {part, idx}, {len, expect} ->
        # account for the `.` separator before every part except the first
        sep = if idx == 0, do: 0, else: 1

        case expect do
          :col ->
            if part == "",
              do: {:halt, {len, expect}},
              else: {:cont, {len + sep + String.length(part), :mod}}

          :mod ->
            cond do
              part in @order_keywords ->
                {:cont, {len + sep + String.length(part), :mod}}

              kw = matching_keyword_prefix(part) ->
                {:halt, {len + sep + String.length(kw), :mod}}

              true ->
                {:halt, {len, expect}}
            end
        end
      end)

    len
  end

  defp matching_keyword_prefix(part) do
    Enum.find(@order_keywords, &String.starts_with?(part, &1))
  end

  # ---- limit/offset --------------------------------------------------------

  defp pg_limit(nil), do: {:ok, nil}
  defp pg_limit(""), do: {:ok, nil}

  defp pg_limit(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> {:ok, n}
      # A negative limit is a distinct 416 PGRST103 (NegativeLimit), not a
      # generic parse error. See pagination case 1254.
      {n, ""} when n < 0 -> {:error, :negative_limit}
      _ -> {:error, :bad_limit}
    end
  end

  defp pg_offset(nil), do: {:ok, nil}
  defp pg_offset(""), do: {:ok, nil}

  defp pg_offset(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> {:ok, n}
      # PostgREST treats a negative offset as a no-op (equivalent to offset 0).
      # See pagination case 1256.
      {n, ""} when n < 0 -> {:ok, nil}
      _ -> {:error, :bad_offset}
    end
  end

  # ---- filters -------------------------------------------------------------

  defp pg_filters(params) do
    {own, embed} =
      params
      |> Enum.reject(fn {k, _v} ->
        base_key(k) in @reserved or String.ends_with?(k, ".order") or
          String.ends_with?(k, ".limit") or String.ends_with?(k, ".offset")
      end)
      |> Enum.split_with(fn {k, _v} -> embed_path(k) == [] end)

    with {:ok, cond_list} <- reduce_filters(own),
         {:ok, with_logic} <- parse_logic(params, cond_list),
         {:ok, embed_filters} <- reduce_embed_filters(embed) do
      {:ok, {with_logic, embed_filters}}
    end
  end

  defp reduce_filters(pairs) do
    # A column repeated in the query string (e.g. `id=gt.1&id=lt.5`) yields one
    # ANDed filter node per occurrence, mirroring PostgREST.
    pairs
    |> Enum.flat_map(fn {key, val} ->
      case val do
        list when is_list(list) -> Enum.map(list, &{key, &1})
        single -> [{key, single}]
      end
    end)
    |> Enum.reduce_while([], fn {key, val}, acc ->
      case parse_column_filter(key, val) do
        {:ok, node} -> {:cont, [node | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, :unprocessable_filter}
      list -> {:ok, list}
    end
  end

  # Embed-targeted filters like `clients.id=eq.1` (and deeper paths). A trailing
  # `and`/`or`/`not.and`/`not.or` segment is an embedded logic tree
  # (`child_entities.or=(...)`, case 1182), parsed into a logic node rather than
  # a column filter. Returns a map: %{["clients"] => [filter_node, ...]}.
  defp reduce_embed_filters(pairs) do
    pairs
    |> Enum.reduce_while(%{}, fn {key, val}, acc ->
      case parse_embed_filter(key, val) do
        {:ok, path, node} -> {:cont, Map.update(acc, path, [node], &[node | &1])}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, :unprocessable_filter}
      map -> {:ok, map}
    end
  end

  # Parse a single embed-targeted filter pair into `{:ok, embed_path, node}`.
  defp parse_embed_filter(key, val) do
    path = embed_path(key)
    last = key |> String.split(".") |> List.last()

    cond do
      # `<embed>.or=(...)` / `<embed>.and=(...)`
      last in ["and", "or"] ->
        op = if last == "or", do: :or, else: :and
        embed_logic_node(path, op, false, val)

      # `<embed>.not.or=(...)` / `<embed>.not.and=(...)`: the path drops the
      # trailing `not`+keyword pair, the negation applies to the group.
      neg = embed_logic_negated(key) ->
        {neg_path, op} = neg
        embed_logic_node(neg_path, op, true, val)

      true ->
        case parse_column_filter(last, val) do
          {:ok, node} -> {:ok, path, node}
          :error -> :error
        end
    end
  end

  defp embed_logic_node(path, op, negate, val) do
    case parse_logic_group(val) do
      {:ok, children} -> {:ok, path, %{logic: op, negate: negate, children: children}}
      _ -> :error
    end
  end

  # For `<embed>...not.and`/`<embed>...not.or`, returns `{embed_path, :and|:or}`
  # (the path with the trailing `not.<kw>` removed), else nil.
  defp embed_logic_negated(key) do
    segments = String.split(key, ".")

    case Enum.split(segments, -2) do
      {head, ["not", kw]} when kw in ["and", "or"] and head != [] ->
        {head, if(kw == "or", do: :or, else: :and)}

      _ ->
        nil
    end
  end

  # The embed path segments of a filter key, e.g. `clients.id` => ["clients"],
  # `a.b.col` => ["a", "b"]. A plain `col` (or json-path `col->x`) => [].
  defp embed_path(key) do
    case String.split(key, ".") do
      [_single] -> []
      segments -> Enum.drop(segments, -1)
    end
  end

  # Logical params: `and=(...)`, `or=(...)`, `not.and=(...)`, `not.or=(...)`.
  defp parse_logic(params, acc) do
    logic =
      params
      |> Enum.filter(fn {k, _v} -> base_key(k) in ["and", "or"] end)
      |> Enum.flat_map(fn {k, v} -> List.wrap(v) |> Enum.map(&{k, &1}) end)

    Enum.reduce_while(logic, {:ok, acc}, fn {k, v}, {:ok, nodes} ->
      negate? = String.starts_with?(k, "not.")
      op = if String.ends_with?(k, "or"), do: :or, else: :and

      case parse_logic_group(v) do
        {:ok, children} ->
          node = %{logic: op, negate: negate?, children: children}
          {:cont, {:ok, [node | nodes]}}

        {:error, :empty_group} ->
          {:halt, {:error, {:logic_parse, v}}}

        :error ->
          {:halt, {:error, :bad_logic}}
      end
    end)
  end

  defp base_key(key) do
    key
    |> String.replace_prefix("not.", "")
    |> String.split(".", parts: 2)
    |> hd()
  end

  # Parse the body of a logic group: `(cond,cond,and(...),or(...))`.
  defp parse_logic_group(raw) do
    inner = raw |> String.trim() |> strip_outer_parens()

    case inner do
      :error ->
        :error

      "" ->
        # empty group like or=() is a zero-arity error in PostgREST: it returns
        # 400 PGRST100 (see filters/logical/arity). Signal a distinct reason so
        # the controller can render the precise parse-error envelope.
        {:error, :empty_group}

      body ->
        body
        |> split_top_commas()
        |> Enum.map(&String.trim/1)
        |> Enum.reduce_while([], fn member, acc ->
          case parse_logic_member(member) do
            {:ok, node} -> {:cont, [node | acc]}
            :error -> {:halt, :error}
          end
        end)
        |> case do
          :error -> :error
          list -> {:ok, Enum.reverse(list)}
        end
    end
  end

  defp parse_logic_member(member) do
    cond do
      member == "" ->
        :error

      logic_prefix(member) ->
        {neg, op, rest} = logic_prefix(member)

        case parse_logic_group(rest) do
          {:ok, children} -> {:ok, %{logic: op, negate: neg, children: children}}
          _ -> :error
        end

      true ->
        # member is `col.op.value` possibly `col.not.op.value`
        case String.split(member, ".", parts: 2) do
          [col, opval] -> parse_filter_expr(String.trim(col), opval)
          _ -> :error
        end
    end
  end

  # Returns {negate?, :and|:or, "(...)"} if member begins with and(/or(/not.and(.
  # Whitespace is permitted between the and/or keyword and its opening paren
  # (AndOrParamsSpec "allows whitespace", case 1169).
  defp logic_prefix(member), do: Nimble.logic_prefix(member)

  # A top-level `col=op.value` filter param.
  defp parse_column_filter(key, val) do
    val = if is_list(val), do: List.last(val), else: val
    parse_filter_expr(String.trim(key), val)
  end

  # Parse `op.value` (with optional `not.` prefix, quantifier `op(any|all)`,
  # fts language `fts(lang)`) against column `col` (which may have a json path).
  defp parse_filter_expr(col_raw, opval),
    do: Nimble.parse_filter_expr(col_raw, opval)

  # ---- shared helpers ------------------------------------------------------

  defp valid_identifier?(col), do: Nimble.valid_identifier?(col)

  # Split on commas that are at the top level (not nested in () or {} or []),
  # and not inside double quotes.
  @doc false
  def split_top_commas(str) do
    do_split(String.to_charlist(str), 0, false, [], [])
  end

  defp do_split([], _depth, _q, cur, acc) do
    Enum.reverse([cur |> Enum.reverse() |> List.to_string() | acc])
  end

  defp do_split([?" | rest], depth, q, cur, acc),
    do: do_split(rest, depth, not q, [?" | cur], acc)

  defp do_split([c | rest], depth, false = q, cur, acc) when c in [?(, ?{, ?[],
    do: do_split(rest, depth + 1, q, [c | cur], acc)

  defp do_split([c | rest], depth, false = q, cur, acc) when c in [?), ?}, ?]],
    do: do_split(rest, depth - 1, q, [c | cur], acc)

  defp do_split([?, | rest], 0, false, cur, acc),
    do: do_split(rest, 0, false, [], [cur |> Enum.reverse() |> List.to_string() | acc])

  defp do_split([c | rest], depth, q, cur, acc),
    do: do_split(rest, depth, q, [c | cur], acc)

  # Strip one layer of outer parentheses; returns inner string or :error.
  defp strip_outer_parens("(" <> _ = s) do
    if String.ends_with?(s, ")") do
      String.slice(s, 1..-2//1)
    else
      :error
    end
  end

  defp strip_outer_parens(_), do: :error
end
