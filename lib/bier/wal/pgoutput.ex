defmodule Bier.Wal.Pgoutput do
  @moduledoc """
  Decoder for PostgreSQL's `pgoutput` logical-replication output plugin,
  protocol version 1.

  `decode/2` takes one pgoutput message (the payload of an XLogData frame)
  plus the relation registry accumulated from prior Relation messages, and
  returns `{event, registry}`. Column values arrive in Postgres text
  representation; converting them to JSON terms is `Bier.Wal.Render`'s
  concern. Validated against a live PostgreSQL 17 stream.
  """

  import Bitwise, only: [&&&: 2]

  # Microseconds between the Postgres epoch (2000-01-01) and the Unix epoch.
  @pg_epoch_offset 946_684_800_000_000

  @spec decode(binary(), map()) :: {map(), map()}
  def decode(message, registry)

  def decode(<<?B, final_lsn::64, commit_ts::64, xid::32>>, reg),
    do: {%{kind: :begin, final_lsn: lsn(final_lsn), commit_at: ts(commit_ts), xid: xid}, reg}

  def decode(<<?C, _flags::8, commit_lsn::64, end_lsn::64, commit_ts::64>>, reg),
    do:
      {%{kind: :commit, lsn: lsn(commit_lsn), end_lsn: lsn(end_lsn), commit_at: ts(commit_ts)},
       reg}

  def decode(<<?O, origin_lsn::64, rest::binary>>, reg) do
    {name, ""} = cstring(rest)
    {%{kind: :origin, lsn: lsn(origin_lsn), name: name}, reg}
  end

  def decode(<<?R, oid::32, rest::binary>>, reg) do
    {namespace, rest} = cstring(rest)
    {relname, rest} = cstring(rest)
    <<replident::8, ncols::16, rest::binary>> = rest

    relation = %{
      oid: oid,
      schema: namespace,
      table: relname,
      replica_identity: replident(replident),
      columns: decode_columns(ncols, rest, [])
    }

    {%{kind: :relation, relation: relation}, Map.put(reg, oid, relation)}
  end

  def decode(<<?Y, oid::32, rest::binary>>, reg) do
    {namespace, rest} = cstring(rest)
    {name, ""} = cstring(rest)
    {%{kind: :type, oid: oid, schema: namespace, name: name}, reg}
  end

  def decode(<<?I, oid::32, ?N, rest::binary>>, reg) do
    {row, ""} = tuple_data(rest)
    {%{kind: :insert, relation: rel!(reg, oid), row: named(reg, oid, row)}, reg}
  end

  def decode(<<?U, oid::32, tag, rest::binary>>, reg) when tag in [?K, ?O] do
    {old, <<?N, rest::binary>>} = tuple_data(rest)
    {row, ""} = tuple_data(rest)

    {%{
       kind: :update,
       relation: rel!(reg, oid),
       old: named(reg, oid, old),
       old_kind: if(tag == ?K, do: :key, else: :full),
       row: named(reg, oid, row)
     }, reg}
  end

  def decode(<<?U, oid::32, ?N, rest::binary>>, reg) do
    {row, ""} = tuple_data(rest)

    {%{
       kind: :update,
       relation: rel!(reg, oid),
       old: nil,
       old_kind: nil,
       row: named(reg, oid, row)
     }, reg}
  end

  def decode(<<?D, oid::32, tag, rest::binary>>, reg) when tag in [?K, ?O] do
    {old, ""} = tuple_data(rest)

    {%{
       kind: :delete,
       relation: rel!(reg, oid),
       old: named(reg, oid, old),
       old_kind: if(tag == ?K, do: :key, else: :full)
     }, reg}
  end

  def decode(<<?T, nrels::32, options::8, rest::binary>>, reg) do
    oids = for <<oid::32 <- rest>>, do: oid

    {%{
       kind: :truncate,
       cascade: (options &&& 1) == 1,
       restart_identity: (options &&& 2) == 2,
       relations: Enum.map(oids, &rel!(reg, &1)),
       count: nrels
     }, reg}
  end

  def decode(<<?M, flags::8, message_lsn::64, rest::binary>>, reg) do
    {prefix, <<len::32, content::binary-size(len)>>} = cstring(rest)

    {%{
       kind: :message,
       transactional: flags == 1,
       lsn: lsn(message_lsn),
       prefix: prefix,
       content: content
     }, reg}
  end

  # TupleData: n columns, each 'n' (null) | 'u' (unchanged TOAST) |
  # 't' len+text | 'b' len+binary (only when the binary option is requested).
  defp tuple_data(<<ncols::16, rest::binary>>), do: tuple_cols(ncols, rest, [])

  defp tuple_cols(0, rest, acc), do: {Enum.reverse(acc), rest}
  defp tuple_cols(n, <<?n, rest::binary>>, acc), do: tuple_cols(n - 1, rest, [nil | acc])

  defp tuple_cols(n, <<?u, rest::binary>>, acc),
    do: tuple_cols(n - 1, rest, [:unchanged_toast | acc])

  defp tuple_cols(n, <<?t, len::32, value::binary-size(len), rest::binary>>, acc),
    do: tuple_cols(n - 1, rest, [value | acc])

  defp tuple_cols(n, <<?b, len::32, value::binary-size(len), rest::binary>>, acc),
    do: tuple_cols(n - 1, rest, [{:binary, value} | acc])

  defp decode_columns(0, "", acc), do: Enum.reverse(acc)

  defp decode_columns(n, <<flags::8, rest::binary>>, acc) do
    {name, <<typoid::32, typmod::signed-32, rest::binary>>} = cstring(rest)

    decode_columns(n - 1, rest, [
      %{name: name, type_oid: typoid, type_mod: typmod, key?: (flags &&& 1) == 1} | acc
    ])
  end

  defp rel!(reg, oid),
    do: Map.get(reg, oid) || raise("pgoutput: data message for unknown relation oid #{oid}")

  # Zip a tuple's positional values with the relation's column names.
  defp named(reg, oid, values) do
    %{columns: cols} = rel!(reg, oid)
    cols |> Enum.map(& &1.name) |> Enum.zip(values) |> Map.new()
  end

  defp cstring(bin) do
    [head, rest] = :binary.split(bin, <<0>>)
    {head, rest}
  end

  defp replident(?d), do: :default
  defp replident(?n), do: :nothing
  defp replident(?f), do: :full
  defp replident(?i), do: :index

  defp lsn(int) do
    <<hi::32, lo::32>> = <<int::64>>
    {hi, lo}
  end

  defp ts(us), do: DateTime.from_unix!(us + @pg_epoch_offset, :microsecond)
end
