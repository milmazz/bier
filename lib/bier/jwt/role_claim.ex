defmodule Bier.JWT.RoleClaim do
  @moduledoc """
  The `jwt-role-claim-key` JSON Path: where in the JWT claims the database role
  lives (default `$.role`).

  PostgREST v16.0 replaced its bespoke leading-dot JSPath DSL with **RFC 9535
  JSON Path** (`PostgREST.Config.JSPath` now delegates to the `aeson-jsonpath`
  package). The migration rules are:

    * every expression starts with the root identifier `$` — `.role` becomes
      `$.role`, so the v14.12 spelling is now a parse error (conformance case
      1711);
    * a member name containing anything but letters, digits and `_` needs the
      bracket selector — `.roles.write-role` becomes `$.roles["write-role"]`;
    * the DSL's string-comparison operators (`^==`, `==^`, `*==`) are gone,
      replaced by the RFC 9535 `search()` function —
      `.roles[?(@ ^== "pg_")]` becomes `$.roles[?search(@, "^pg_")]`.

  Bier ships dependency-free, so this module hand-writes the subset of RFC 9535
  that `jwt-role-claim-key` values actually use, mirroring `aeson-jsonpath`'s
  parser and `dumpQuery`:

    * root `$` followed by child segments;
    * the dotted member-name shorthand (`.name`);
    * bracketed name selectors, single- or double-quoted with the RFC's escape
      forms (`["a-b"]`, `['a-b']`);
    * bracketed integer index selectors, negative counting from the end
      (`[0]`, `[-1]`);
    * bracketed filter selectors holding one comparison (`[?(@ == "x")]`, also
      `<`/`<=`/`>`/`>=`/`!=`) or one `search()` test
      (`[?search(@, "^pg_")]`), with the comparables being a literal or a
      singular query rooted at `@` or `$`.

  Deliberately **not** modelled (they parse upstream but are rejected here, and
  no PostgREST fixture or documented role-claim value uses them): descendant
  segments (`..`), wildcards (`*`), array slices, comma-separated multi
  selectors, and the `&&`/`||`/`!` logical combinators.

  `dump/1` renders the canonical RFC 9535 text the way `aeson-jsonpath`'s
  `dumpQuery` does (bracketed names and string literals in single quotes,
  filters unparenthesized unless the source had parentheses). The extra
  `"` -> `\\"` and `$` -> `$$` escaping `dumpJSPath` applies for
  `--dump-config` is the config layer's job (`Bier.CLI.Config`), because the
  escaped text is not a re-parseable JSON Path.

  ## Two deliberate divergences from `dumpQuery`

  Upstream's `dumpQuery` is write-only: it wraps member names and string
  literals in single quotes with no escaping at all
  (`DumpQuery.hs`, `Name txt -> "'" <> txt <> "'"`) and always writes a
  singular-query name segment dotted (`NameSQSeg txt -> "." <> txt`). Both
  emit text its own parser rejects — `$["it's"]` comes back out as
  `$['it's']`, `$.a[?(@["x-y"] == "z")]` as `$.a[?(@.x-y == 'z')]`.

  Bier cannot inherit that, because unlike upstream it *re-reads* its own dump:
  `Bier.CLI.Config` canonicalises `jwt-role-claim-key` through `dump/1` and
  then hands that text to `Bier.start_link/1`, and conformance case 1726 pins
  the rule that a dumped config, written back to a file and re-dumped, is
  byte-identical. So `dump/1`:

    * escapes the enclosing quote, the backslash and the control characters
      inside a quoted name or string literal, using RFC 9535's `escapable`
      forms — plus `\\u0022` for `"`, which is legal bare inside a
      single-quoted string but would not survive `dumpJSPath`'s
      `"` -> `\\"` rewrite and the config reader's undo of it;
    * writes a singular-query name segment dotted only when the name *is* a
      bare dotted shorthand, and brackets it otherwise.

  The two agree byte for byte on every value upstream dumps re-parseably,
  with one exception implied by the bullet above: a name or literal holding a
  bare `"`, which upstream leaves as-is (`$['a"b']`) and Bier escapes
  (`$['a\\u0022b']`) so the config round-trip survives.

  Extraction evaluates the query against the decoded claims and yields the
  first selected node when it is a non-empty JSON string — the same rule the
  default `role` claim always had.

  A filter applied to an *object* selects its members in ascending member-name
  order. RFC 9535 leaves that order implementation-defined but requires each
  implementation to pick one; upstream inherits `aeson`'s `KeyMap` traversal
  order, which Elixir has no equivalent of — and plain map iteration order is
  unspecified here and changes with map size, which would let identical claims
  resolve to *different* database roles across boots. Sorting by member name is
  the only order Bier can reproduce deterministically.
  """

  @type name_form :: :dot | :bracket

  @type segment ::
          {:name, name_form(), String.t()}
          | {:index, integer()}
          | {:filter, expr()}

  @type op :: :eq | :ne | :lt | :le | :gt | :ge

  @type comparable :: {:lit, term()} | {:query, :current | :root, [segment()]}

  @type expr ::
          {:paren, expr()}
          | {:comparison, comparable(), op(), comparable()}
          | {:search, comparable(), comparable()}

  @type path :: [segment()]

  # Member-name shorthand: aeson-jsonpath's pDotted accepts an ASCII letter,
  # `_` or any codepoint >= 0x80 first, then those plus ASCII digits.
  @dotted_name ~r/^[A-Za-z_\x{80}-\x{10FFFF}][A-Za-z0-9_\x{80}-\x{10FFFF}]*/u
  @index ~r/^-?[0-9]+/
  @number ~r/^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?/

  @doc """
  Parse a `jwt-role-claim-key` JSON Path. Returns `{:ok, path}` or
  `{:error, message}` with PostgREST's pinned message (case 1711).
  """
  @spec parse(String.t()) :: {:ok, path()} | {:error, String.t()}
  def parse("$" <> rest = input) do
    case segments(rest, []) do
      {:ok, path} -> {:ok, path}
      :error -> parse_error(input)
    end
  end

  def parse(input) when is_binary(input), do: parse_error(input)

  defp parse_error(input), do: {:error, "failed to parse role-claim-key value (#{input})"}

  defp segments("", acc), do: {:ok, Enum.reverse(acc)}

  defp segments(rest, acc) do
    case segment(rest) do
      {:ok, seg, rest} -> segments(rest, [seg | acc])
      :error -> :error
    end
  end

  # Descendant segments (`..name`) are outside the supported subset.
  defp segment(".." <> _rest), do: :error
  defp segment("." <> rest), do: dotted_name(rest)
  defp segment("[" <> rest), do: bracketed(rest)
  defp segment(_other), do: :error

  defp dotted_name(input) do
    case Regex.run(@dotted_name, input) do
      [name] -> {:ok, {:name, :dot, name}, consume(input, name)}
      nil -> :error
    end
  end

  defp bracketed(input) do
    with {:ok, selector, rest} <- selector(skip_ws(input)),
         "]" <> rest <- skip_ws(rest) do
      {:ok, selector, rest}
    else
      _other -> :error
    end
  end

  defp selector("?" <> rest) do
    with {:ok, expr, rest} <- logical(skip_ws(rest)), do: {:ok, {:filter, expr}, rest}
  end

  defp selector(<<quote_char, _rest::binary>> = input) when quote_char in [?', ?"] do
    with {:ok, name, rest} <- quoted(input), do: {:ok, {:name, :bracket, name}, rest}
  end

  defp selector(input), do: index(input)

  defp index(input) do
    case Regex.run(@index, input) do
      [digits] -> {:ok, {:index, String.to_integer(digits)}, consume(input, digits)}
      nil -> :error
    end
  end

  # aeson-jsonpath's pBasicExpr order: parenthesized group, then comparison,
  # then a bare test expression (here only `search()`).
  defp logical("(" <> rest) do
    with {:ok, expr, rest} <- logical(skip_ws(rest)),
         ")" <> rest <- skip_ws(rest) do
      {:ok, {:paren, expr}, rest}
    else
      _other -> :error
    end
  end

  defp logical(input) do
    case comparison(input) do
      {:ok, _expr, _rest} = ok -> ok
      :error -> function_test(input)
    end
  end

  defp comparison(input) do
    with {:ok, left, rest} <- comparable(input),
         {:ok, op, rest} <- operator(skip_ws(rest)),
         {:ok, right, rest} <- comparable(skip_ws(rest)) do
      {:ok, {:comparison, left, op, right}, rest}
    else
      _other -> :error
    end
  end

  defp operator(">=" <> rest), do: {:ok, :ge, rest}
  defp operator("<=" <> rest), do: {:ok, :le, rest}
  defp operator(">" <> rest), do: {:ok, :gt, rest}
  defp operator("<" <> rest), do: {:ok, :lt, rest}
  defp operator("!=" <> rest), do: {:ok, :ne, rest}
  defp operator("==" <> rest), do: {:ok, :eq, rest}
  defp operator(_other), do: :error

  # `search()` is the only function aeson-jsonpath implements (FunctionSearch).
  defp function_test("search" <> rest) do
    with "(" <> rest <- rest,
         {:ok, first, rest} <- comparable(skip_ws(rest)),
         "," <> rest <- skip_ws(rest),
         {:ok, second, rest} <- comparable(skip_ws(rest)),
         ")" <> rest <- skip_ws(rest) do
      {:ok, {:search, first, second}, rest}
    else
      _other -> :error
    end
  end

  defp function_test(_other), do: :error

  defp comparable(input) do
    case literal(input) do
      {:ok, _lit, _rest} = ok -> ok
      :error -> singular_query(input)
    end
  end

  defp literal(<<quote_char, _rest::binary>> = input) when quote_char in [?', ?"] do
    with {:ok, text, rest} <- quoted(input), do: {:ok, {:lit, text}, rest}
  end

  defp literal("true" <> rest), do: {:ok, {:lit, true}, rest}
  defp literal("false" <> rest), do: {:ok, {:lit, false}, rest}
  defp literal("null" <> rest), do: {:ok, {:lit, nil}, rest}

  defp literal(input) do
    case Regex.run(@number, input) do
      [number | _groups] -> {:ok, {:lit, to_number(number)}, consume(input, number)}
      nil -> :error
    end
  end

  defp to_number(text) do
    if String.contains?(text, [".", "e", "E"]) do
      {value, _rest} = Float.parse(text)
      value
    else
      String.to_integer(text)
    end
  end

  # A singular query: `@` (current node) or `$` (root) plus name/index
  # segments. Whitespace may precede a segment; when no further segment
  # follows, the unconsumed input (whitespace included) is handed back.
  defp singular_query("@" <> rest), do: singular_segments(rest, :current, [])
  defp singular_query("$" <> rest), do: singular_segments(rest, :root, [])
  defp singular_query(_other), do: :error

  defp singular_segments(input, kind, acc) do
    case singular_segment(skip_ws(input)) do
      {:ok, seg, rest} -> singular_segments(rest, kind, [seg | acc])
      :error -> {:ok, {:query, kind, Enum.reverse(acc)}, input}
    end
  end

  defp singular_segment("." <> rest), do: dotted_name(rest)

  defp singular_segment("[" <> rest) do
    case singular_selector(rest) do
      {:ok, seg, "]" <> rest} -> {:ok, seg, rest}
      _other -> :error
    end
  end

  defp singular_segment(_other), do: :error

  defp singular_selector(<<quote_char, _rest::binary>> = input) when quote_char in [?', ?"] do
    with {:ok, name, rest} <- quoted(input), do: {:ok, {:name, :bracket, name}, rest}
  end

  defp singular_selector(input), do: index(input)

  # RFC 9535 quoted strings: the "other" quote character is literal inside a
  # string, the matching one must be escaped.
  defp quoted(<<quote_char, rest::binary>>) when quote_char in [?', ?"],
    do: quoted_chars(rest, quote_char, [])

  defp quoted_chars(<<quote_char, rest::binary>>, quote_char, acc),
    do: {:ok, acc |> Enum.reverse() |> List.to_string(), rest}

  defp quoted_chars(<<?\\, rest::binary>>, quote_char, acc) do
    case escape(rest, quote_char) do
      {:ok, char, rest} -> quoted_chars(rest, quote_char, [char | acc])
      :error -> :error
    end
  end

  defp quoted_chars(<<char::utf8, rest::binary>>, quote_char, acc) do
    if unescaped?(char) or (char in [?', ?"] and char != quote_char) do
      quoted_chars(rest, quote_char, [char | acc])
    else
      :error
    end
  end

  defp quoted_chars(_other, _quote_char, _acc), do: :error

  # pUnescaped: every codepoint from 0x20 up except `"`, `'` and `\`. The RFC's
  # explicit upper bounds (skipping the surrogate block, stopping at 0x10FFFF)
  # need no test here — the caller matched the character as `utf8`, so it is
  # already a valid scalar value.
  defp unescaped?(char), do: char >= 0x20 and char not in [?", ?', ?\\]

  defp escape(<<?b, rest::binary>>, _quote_char), do: {:ok, ?\b, rest}
  defp escape(<<?f, rest::binary>>, _quote_char), do: {:ok, ?\f, rest}
  defp escape(<<?n, rest::binary>>, _quote_char), do: {:ok, ?\n, rest}
  defp escape(<<?r, rest::binary>>, _quote_char), do: {:ok, ?\r, rest}
  defp escape(<<?t, rest::binary>>, _quote_char), do: {:ok, ?\t, rest}
  defp escape(<<?/, rest::binary>>, _quote_char), do: {:ok, ?/, rest}
  defp escape(<<?\\, rest::binary>>, _quote_char), do: {:ok, ?\\, rest}
  defp escape(<<quote_char, rest::binary>>, quote_char), do: {:ok, quote_char, rest}
  defp escape(<<?u, rest::binary>>, _quote_char), do: hex_escape(rest)
  defp escape(_other, _quote_char), do: :error

  defp hex_escape(input) do
    with {:ok, code, rest} <- hex4(input) do
      cond do
        code in 0xD800..0xDBFF -> low_surrogate(rest, code)
        code in 0xDC00..0xDFFF -> :error
        true -> {:ok, code, rest}
      end
    end
  end

  defp low_surrogate(<<"\\u", rest::binary>>, high) do
    case hex4(rest) do
      {:ok, low, rest} when low in 0xDC00..0xDFFF ->
        {:ok, (high - 0xD800) * 0x400 + (low - 0xDC00) + 0x10000, rest}

      _other ->
        :error
    end
  end

  defp low_surrogate(_other, _high), do: :error

  defp hex4(<<digits::binary-size(4), rest::binary>>) do
    case Integer.parse(digits, 16) do
      {code, ""} -> {:ok, code, rest}
      _other -> :error
    end
  end

  defp hex4(_other), do: :error

  # RFC 9535 whitespace (aeson-jsonpath's pSpaces).
  defp skip_ws(<<char, rest::binary>>) when char in [?\s, ?\n, ?\r, ?\t], do: skip_ws(rest)
  defp skip_ws(rest), do: rest

  defp consume(input, taken),
    do: binary_part(input, byte_size(taken), byte_size(input) - byte_size(taken))

  @doc """
  Render a parsed path as canonical RFC 9535 text, mirroring `aeson-jsonpath`'s
  `dumpQuery`: bracketed names and string literals use single quotes, indexes
  render bare, and a filter renders as `[?<expr>]`.
  """
  @spec dump(path()) :: String.t()
  def dump(path), do: "$" <> Enum.map_join(path, "", &dump_segment/1)

  defp dump_segment({:name, :dot, name}), do: "." <> name
  defp dump_segment({:name, :bracket, name}), do: bracket_name(name)
  defp dump_segment({:index, index}), do: "[#{index}]"
  defp dump_segment({:filter, expr}), do: "[?" <> dump_expr(expr) <> "]"

  defp dump_expr({:paren, expr}), do: "(" <> dump_expr(expr) <> ")"

  defp dump_expr({:comparison, left, op, right}),
    do: dump_singular(left) <> " " <> op_text(op) <> " " <> dump_singular(right)

  defp dump_expr({:search, first, second}),
    do: "search(" <> dump_query(first) <> ", " <> dump_query(second) <> ")"

  defp op_text(:eq), do: "=="
  defp op_text(:ne), do: "!="
  defp op_text(:lt), do: "<"
  defp op_text(:le), do: "<="
  defp op_text(:gt), do: ">"
  defp op_text(:ge), do: ">="

  # A comparable query is a SingularQuery upstream, whose AST keeps only the
  # member name — so both bracketed and dotted names dump dotted. Bier only
  # follows that when the name really is a bare dotted shorthand; upstream's
  # unconditional `"." <> txt` would otherwise emit unparseable text (see the
  # moduledoc).
  defp dump_singular({:query, kind, segments}),
    do: query_root(kind) <> Enum.map_join(segments, "", &dump_singular_segment/1)

  defp dump_singular(literal), do: dump_literal(literal)

  defp dump_singular_segment({:name, _form, name}) do
    if dotted_shorthand?(name), do: "." <> name, else: bracket_name(name)
  end

  defp dump_singular_segment({:index, index}), do: "[#{index}]"

  defp dotted_shorthand?(name), do: Regex.run(@dotted_name, name) == [name]

  defp bracket_name(name), do: "['" <> escape_quoted(name) <> "']"

  # A function argument keeps the full Query AST upstream, so its segments dump
  # in the same form they were written.
  defp dump_query({:query, kind, segments}),
    do: query_root(kind) <> Enum.map_join(segments, "", &dump_segment/1)

  defp dump_query(literal), do: dump_literal(literal)

  defp query_root(:root), do: "$"
  defp query_root(:current), do: "@"

  defp dump_literal({:lit, nil}), do: "null"
  defp dump_literal({:lit, true}), do: "true"
  defp dump_literal({:lit, false}), do: "false"
  defp dump_literal({:lit, text}) when is_binary(text), do: "'" <> escape_quoted(text) <> "'"
  defp dump_literal({:lit, number}), do: to_string(number)

  # Inverse of `quoted/1` for the single-quote form: the enclosing quote, the
  # backslash and the control characters get RFC 9535 `escapable` forms. `"` is
  # legal bare inside a single-quoted string, but `Bier.CLI.Config` rewrites it
  # to `\\"` on the way into a `--dump-config` line and the config reader undoes
  # that, so it is escaped numerically to keep the file round trip stable.
  defp escape_quoted(text), do: for(<<char::utf8 <- text>>, into: "", do: escape_char(char))

  defp escape_char(?'), do: ~S(\')
  defp escape_char(?\\), do: ~S(\\)
  defp escape_char(?"), do: ~S(\u0022)
  defp escape_char(?\b), do: ~S(\b)
  defp escape_char(?\f), do: ~S(\f)
  defp escape_char(?\n), do: ~S(\n)
  defp escape_char(?\r), do: ~S(\r)
  defp escape_char(?\t), do: ~S(\t)

  defp escape_char(char) when char < 0x20,
    do:
      "\\u" <> (char |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))

  defp escape_char(char), do: <<char::utf8>>

  @doc """
  Evaluate `path` against the decoded claims. RFC 9535 queries produce a
  nodelist; PostgREST takes its first element and uses it only when it is a
  non-empty JSON string (missing, wrong type or empty yields `nil`).
  """
  @spec extract(map(), path()) :: String.t() | nil
  def extract(claims, path) do
    case claims |> select_nodes(path, claims) |> List.first() do
      role when is_binary(role) and role != "" -> role
      _other -> nil
    end
  end

  defp select_nodes(node, path, root),
    do: Enum.reduce(path, [node], fn segment, nodes -> apply_segment(segment, nodes, root) end)

  defp apply_segment(segment, nodes, root),
    do: Enum.flat_map(nodes, &select_from(segment, &1, root))

  defp select_from({:name, _form, name}, node, _root) when is_map(node) do
    case Map.fetch(node, name) do
      {:ok, value} -> [value]
      :error -> []
    end
  end

  defp select_from({:index, index}, node, _root) when is_list(node) do
    offset = if index < 0, do: length(node) + index, else: index

    with true <- offset >= 0,
         {:ok, value} <- Enum.fetch(node, offset) do
      [value]
    else
      _other -> []
    end
  end

  defp select_from({:filter, expr}, node, root) when is_list(node),
    do: Enum.filter(node, &truthy?(expr, &1, root))

  # Ascending member name, not `Map.values/1`: Elixir's map iteration order is
  # unspecified and flips between the small-map and the hash-map layout, so an
  # object filter would otherwise resolve to a different role across boots —
  # in the path that picks the database role. RFC 9535 leaves the order
  # implementation-defined but requires one fixed choice (see the moduledoc).
  defp select_from({:filter, expr}, node, root) when is_map(node) do
    node
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {_name, value} ->
      if truthy?(expr, value, root), do: [value], else: []
    end)
  end

  defp select_from(_segment, _node, _root), do: []

  defp truthy?({:paren, expr}, node, root), do: truthy?(expr, node, root)

  defp truthy?({:comparison, left, op, right}, node, root),
    do: compare(op, value_of(left, node, root), value_of(right, node, root))

  defp truthy?({:search, first, second}, node, root),
    do: search?(value_of(first, node, root), value_of(second, node, root))

  defp value_of({:lit, value}, _node, _root), do: {:value, value}

  defp value_of({:query, kind, segments}, node, root) do
    start = if kind == :root, do: root, else: node

    case select_nodes(start, segments, root) do
      [value | _rest] -> {:value, value}
      [] -> :nothing
    end
  end

  defp compare(:eq, left, right), do: equal?(left, right)
  defp compare(:ne, left, right), do: not equal?(left, right)
  defp compare(:lt, left, right), do: ordered?(left, right, &</2)
  defp compare(:le, left, right), do: equal?(left, right) or ordered?(left, right, &</2)
  defp compare(:gt, left, right), do: ordered?(left, right, &>/2)
  defp compare(:ge, left, right), do: equal?(left, right) or ordered?(left, right, &>/2)

  defp equal?(:nothing, :nothing), do: true
  defp equal?({:value, left}, {:value, right}), do: json_equal?(left, right)
  defp equal?(_left, _right), do: false

  defp json_equal?(left, right) when is_number(left) and is_number(right), do: left == right
  defp json_equal?(left, right), do: left === right

  # RFC 9535 orders only numbers against numbers and strings against strings;
  # every other pairing is false.
  defp ordered?({:value, left}, {:value, right}, fun)
       when is_number(left) and is_number(right),
       do: fun.(left, right)

  defp ordered?({:value, left}, {:value, right}, fun)
       when is_binary(left) and is_binary(right),
       do: fun.(left, right)

  defp ordered?(_left, _right, _fun), do: false

  # RFC 9535 `search()` is an unanchored regexp search over a string node.
  defp search?({:value, subject}, {:value, pattern})
       when is_binary(subject) and is_binary(pattern) do
    case Regex.compile(pattern, "u") do
      {:ok, regex} -> Regex.match?(regex, subject)
      {:error, _reason} -> false
    end
  end

  defp search?(_subject, _pattern), do: false
end
