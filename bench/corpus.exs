# Shared benchmark/parity corpus for the QueryParser backends.
#
# Loaded via `Code.require_file("corpus.exs", __DIR__)` from the bench scripts.
# Builds per-function input lists from BOTH the conformance cases
# (`spec/conformance/cases/*.yaml`, the `request.path` query parts) and a set of
# hand-picked edge cases (json paths, quantifiers, quoted values, related order,
# deep json path, long select lists, balanced-nesting comma splits).

defmodule Bench.Corpus do
  @cases_dir Path.expand("../spec/conformance/cases", __DIR__)

  @doc "Raw query strings (everything after `?`) extracted from conformance cases."
  def query_strings do
    @cases_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".yaml"))
    |> Enum.map(&Path.join(@cases_dir, &1))
    |> Enum.flat_map(&extract_query/1)
    |> Enum.uniq()
  end

  # Very small line-based extractor (avoids a YAML dep): pull the `path:` value
  # and keep the part after `?`. The harness already URL-decodes `+`→space, but
  # here we feed the raw query string straight to `parse_request/1` (which decodes
  # internally), matching the production call.
  defp extract_query(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*path:\s*(.+?)\s*$/, line) do
        [_, raw] ->
          path = raw |> String.trim() |> String.trim("\"") |> String.trim("'")

          case String.split(path, "?", parts: 2) do
            [_, qs] when qs != "" -> [qs]
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  # ---- hand-picked edge cases per leaf grammar -----------------------------

  def json_paths do
    base = [
      "col",
      "data->foo->>bar",
      "settings->foo->>int",
      "data->0",
      "data->>-3",
      "data->>id",
      "a->b->c->d->e->>f",
      "field-with_sep",
      "data->>--34",
      "data-> ->x",
      "col->",
      "data->key with space",
      "col->>0->>1->>2->>3->>4->>5"
    ]

    base ++ collect(:json_path)
  end

  def op_values do
    base = [
      "eq.5",
      "neq.10",
      "gte.13",
      "lt.0",
      "in.(1,2,3)",
      "is.null",
      "like.*plan*",
      "eq(any).{3,4,5}",
      "gt(all).{4,3}",
      "fts(english).cat",
      "phfts(german).the cat",
      "cs.{1,2,3}",
      "ov.{2,3}",
      "match(any).{stop,thing}",
      "not_a_valid_op_because_caps.x",
      "adj.{2,3}"
    ]

    base ++ collect(:op_value)
  end

  def filter_exprs do
    [
      {"id", "eq.5"},
      {"id", "not.eq.5"},
      {"age", "gte.13"},
      {"name", "like.*plan*"},
      {"id", "in.(1,2,3)"},
      {"data->foo->>bar", "eq.baz"},
      {"data->foo->>bar", "not.eq.baz"},
      {"body", "ilike(all).{%plan%,%greatness%}"},
      {"arr", "cs.{1,2}"},
      {"text_search_vector", "fts.foo"},
      {"field-with_sep", "eq.3"},
      {"1bad", "eq.x"},
      {"settings->a->>b", "is.null"}
    ]
  end

  def order_terms do
    base = [
      "id",
      "id.asc",
      "id.desc",
      "id.asc.nullsfirst",
      "age.desc.nullslast",
      "id.nullsfirst",
      "settings->foo->>bar",
      "settings->foo->>bar.desc",
      "tasks(name).asc",
      "clients(id).desc.nullsfirst",
      "tasks(data->>x).asc.nullslast",
      "id.asc.nullslasttt",
      "id.left",
      "field-with_sep.desc"
    ]

    base ++ collect(:order)
  end

  def scalar_selects do
    base = [
      "id",
      "name",
      "myId:id",
      "myId:id::text",
      "ciId:id::text",
      "settings->foo->>bar",
      "myBar:settings->foo->>bar",
      "settings->foo->>int::integer",
      "field-with_sep",
      "fullName:full_name",
      "data->0->>1"
    ]

    base ++ collect(:scalar)
  end

  def embed_fields do
    [
      "clients(*)",
      "tasks(id,name)",
      "alias:tasks(id)",
      "the_tasks:tasks(id,name)",
      "project_client:clients(*)",
      "children(id,name)",
      "users(id,name)",
      "child_entities()",
      "rel!hint(id)",
      "rel!inner(id)",
      "just_a_column",
      "data->foo",
      "myId:id::text"
    ]
  end

  def aggregate_fields do
    [
      "count()",
      "col.sum()",
      "alias:col.sum()",
      "amount.avg()::integer",
      "max()",
      "min()",
      "child_entities()",
      "just_a_column",
      "id.foo()",
      "count() "
    ]
  end

  def comma_splits do
    [
      "id,name,age",
      "id,name,clients(*),tasks(id,name)",
      "a,b,and(id.eq.1,id.eq.2),c",
      "arr.cs.{1,2,3},name.eq.x",
      "or(id.eq.1,id.eq.2),and(a.eq.1,b.eq.2)",
      "data->>0,data->>1",
      ~s({1,"a,b,c",2}),
      "deep(a(b(c,d),e),f),g",
      "a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z",
      "id, name, clients(*), tasks(id, name)"
    ]
  end

  def identifiers do
    [
      "id",
      "first_name",
      "field-with_sep",
      "a b c",
      "_private",
      "1bad",
      "with.dot",
      "col(paren",
      "café",
      ""
    ]
  end

  # End-to-end realistic query-string mix for `parse_request/1`.
  def request_mix do
    handpicked = [
      "id=eq.5",
      "id=gt.1&id=lt.5&select=id&limit=2&offset=1",
      "select=id,name,tasks(id,name,users(id,name))&tasks.order=name.asc&tasks.users.order=name.desc",
      "and=(id.eq.1,name.eq.entity 1)&or=(id.eq.1,id.eq.2)&select=id",
      "select=myId:id::text,ciName:name&id=eq.3",
      "data->foo->>bar=eq.baz&select=settings->foo->>bar",
      "order=id.desc,name.asc.nullsfirst&id=in.(1,2,3)",
      "select=count(),amount.sum()::integer&order=id.asc",
      "body=ilike(all).{%plan%,%greatness%}&select=id",
      "child_entities.or=(id.eq.1,name.eq.child entity 2)&select=id,child_entities(id)"
    ]

    (handpicked ++ Enum.take(query_strings(), 80)) |> Enum.uniq()
  end

  # Pull conformance-derived tokens relevant to a given leaf grammar by decoding
  # the query strings and harvesting the matching value/field fragments.
  defp collect(kind) do
    query_strings()
    |> Enum.flat_map(&decode_pairs/1)
    |> Enum.flat_map(fn {k, v} -> tokens_for(kind, k, v) end)
    |> Enum.uniq()
  end

  defp decode_pairs(qs) do
    qs
    |> String.split("&")
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {url_decode(k), url_decode(v)}
        [k] -> {url_decode(k), ""}
      end
    end)
  end

  defp url_decode(s), do: s |> String.replace("+", " ") |> URI.decode()

  @reserved ~w(select order limit offset on_conflict columns and or not)

  defp tokens_for(:op_value, k, v) do
    if base_key(k) in @reserved or String.contains?(k, "."), do: [], else: [v]
  end

  defp tokens_for(:json_path, k, _v) do
    if base_key(k) in @reserved, do: [], else: [k]
  end

  defp tokens_for(:order, "order", v), do: top_commas(v)
  defp tokens_for(:order, _, _), do: []

  defp tokens_for(:scalar, "select", v) do
    top_commas(v)
    |> Enum.reject(&(String.contains?(&1, "(") or String.starts_with?(&1, "...")))
  end

  defp tokens_for(:scalar, _, _), do: []

  defp base_key(k) do
    k
    |> String.replace_prefix("not.", "")
    |> String.split(".", parts: 2)
    |> hd()
  end

  defp top_commas(v), do: Bier.QueryParser.split_top_commas(v) |> Enum.map(&String.trim/1)
end
