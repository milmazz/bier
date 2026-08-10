defmodule Bier.Preferences do
  @moduledoc """
  Parsing and validation of the `Prefer` request header for the **read** path
  (the write path's `Prefer` handling lives in `Bier.Mutation`).

  Mirrors PostgREST v16.0's `ApiRequest.Preferences` semantics:

    * a preference is recognized by its WHOLE token, not by its key:
      `acceptedPrefs` is the list of canonical `<key>=<value>` strings the
      `ToHeaderValue` instances produce, and `isUnacceptable` tests membership in
      it (`Preferences.hs#L145-L163`). Only `timezone=` and `max-affected=`,
      whose values are free-form, are matched by prefix. A token with a known key
      but an unknown value (`count=none`, `return=bogus`) is therefore *invalid*,
      not merely ignored;
    * `handling=strict` rejects the whole request (400 `PGRST122`) when ANY
      supplied preference is invalid. The error `details` lists the offending
      tokens verbatim, comma-separated;
    * `handling=lenient` (or no handling) silently ignores invalid preferences;
    * `timezone=<value>` is **never** an invalid preference. v16.0 dropped the
      `pg_timezone_names` membership test that v14.12 applied
      (`fromHeaders` lost its `TimezoneNames` argument along with
      `isTimezonePrefAccepted`, `Preferences.hs#L129-L163`), so every value is
      accepted as a preference and handed to PostgreSQL as the session
      `TimeZone`. A value PostgreSQL rejects therefore surfaces as an ordinary
      database error (SQLSTATE `22023` -> 400), not as a `PGRST122` — and
      `handling` has nothing left to suppress, which is why the docs say
      "handling=lenient is ignored for timezone. Invalid time zones always
      return an error";
    * the applied preferences are echoed in `Preference-Applied` in PostgREST's
      canonical `prefsVals` order — resolution, missing, representation, count,
      transaction, handling, timezone, max-affected
      (`Preferences.hs#L179-L188`) — never in request order. On a read only
      `count`, `handling` and `timezone` can apply, so the echo is
      `count` before `handling` before `timezone`.

  Numeric UTC offsets (`+05:30`, `-4`) are consequently valid too: they are not
  members of `pg_timezone_names` but PostgreSQL accepts them as a `TimeZone`,
  and the echo carries the raw preference token rather than a normalized zone
  name.
  """

  # `acceptedPrefs` (Preferences.hs#L145-L150): every canonical token produced by
  # a `ToHeaderValue` instance. `tx=` is listed unconditionally upstream, even
  # though the transaction preference is only *honored* with `db-tx-end`
  # configured to allow the override.
  @accepted_tokens ~w(
    resolution=merge-duplicates resolution=ignore-duplicates
    return=representation return=minimal return=headers-only
    count=exact count=planned count=estimated
    tx=commit tx=rollback
    missing=default missing=null
    handling=strict handling=lenient
  )

  # The two preferences whose value is free-form and so cannot be enumerated;
  # `isUnacceptable` matches them by prefix (Preferences.hs#L161-L163).
  @accepted_prefixes ["timezone=", "max-affected="]

  # The `count=` tokens `parsePrefs [ExactCount, PlannedCount, EstimatedCount]`
  # recognizes (Preferences.hs#L134), mapped to the mode the read path applies.
  # This map is the ONLY place the `count=` vocabulary is spelled out —
  # `Bier.Pagination.count_mode/1` delegates here rather than re-deriving it, so
  # the "recognized" and "invalid" classifications cannot drift apart.
  # `count=none` is deliberately absent: it is not a `PreferCount` constructor,
  # so it never matches (leaving the default, no-count state) and it is not in
  # `@accepted_tokens` either, which is what makes it a `handling=strict`
  # violation.
  @count_modes %{
    "count=exact" => :exact,
    "count=planned" => :planned,
    "count=estimated" => :estimated
  }

  @typedoc "The `Prefer: count=` mode a request resolves to."
  @type count_mode :: :none | :exact | :planned | :estimated

  @doc """
  The `Prefer: count=` mode the request asks for, or `:none` when it asks for
  none (PostgREST's `preferCount = Nothing` default).

  `parsePrefs` walks the REQUEST tokens and returns the first that is a known
  count token (`Preferences.hs#L165-L167`), so with several present the earliest
  in the header wins — request order, not the order of the internal constructor
  list (`Preferences.hs#L98-L101`).
  """
  @spec count_mode(Plug.Conn.t()) :: count_mode()
  def count_mode(conn) do
    conn
    |> tokens()
    |> count_token()
    |> mode_for()
  end

  defp mode_for(nil), do: :none
  defp mode_for(token), do: Map.fetch!(@count_modes, token)

  @doc """
  Put the `Preference-Applied` echo (from `parse_read/1`'s `:applied` list) on a
  response, omitting the header entirely when nothing applied.

  Both the relation-read and the `/rpc/` paths call this: `responsePreferences`
  masks the mutation-only preferences per plan but passes `preferCount` (and
  handling/timezone) through untouched for EVERY plan (`Response.hs#L296`), and
  the RPC dispatch builds its `prefHeader` from that same rewritten set
  (`Response.hs#L184`). One rule, one call site.
  """
  @spec put_applied(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def put_applied(conn, []), do: conn

  def put_applied(conn, tokens),
    do: Plug.Conn.put_resp_header(conn, "preference-applied", Enum.join(tokens, ", "))

  @doc """
  Parse the connection's `Prefer` header for a read.

  Returns:

    * `{:ok, %{timezone: tz | nil, applied: [token]}}` — the timezone to hand to
      PostgreSQL (nil when none was requested) and the tokens to echo in
      `Preference-Applied`.
    * `{:error, {:invalid_prefs, details}}` — `handling=strict` with one or more
      invalid preferences; `details` is the `"Invalid preferences: a, b"` string.
  """
  def parse_read(conn) do
    tokens = tokens(conn)
    handling = handling(tokens)
    invalid = invalid_tokens(tokens)

    if handling == :strict and invalid != [] do
      {:error, {:invalid_prefs, "Invalid preferences: " <> Enum.join(invalid, ", ")}}
    else
      timezone = timezone_value(tokens)

      {:ok,
       %{
         timezone: timezone,
         applied: applied_tokens(count_token(tokens), handling, timezone)
       }}
    end
  end

  defp handling(tokens) do
    cond do
      "handling=strict" in tokens -> :strict
      "handling=lenient" in tokens -> :lenient
      true -> nil
    end
  end

  defp timezone_value(tokens) do
    Enum.find_value(tokens, fn
      "timezone=" <> tz -> tz
      _ -> nil
    end)
  end

  defp count_token(tokens), do: Enum.find(tokens, &is_map_key(@count_modes, &1))

  # Tokens that make a `handling=strict` request invalid: any token that is not
  # one of the canonical accepted tokens and does not carry a free-form
  # (`timezone=` / `max-affected=`) prefix. A `timezone` token is always
  # recognized in v16.0 regardless of its value — PostgreSQL, not PostgREST,
  # judges it — while `count=none` is not a `PreferCount` value at all and so is
  # invalid despite its recognized key.
  defp invalid_tokens(tokens), do: Enum.reject(tokens, &accepted?/1)

  defp accepted?(token) do
    token in @accepted_tokens or
      Enum.any?(@accepted_prefixes, &String.starts_with?(token, &1))
  end

  # Echo, in PostgREST's canonical `prefsVals` order, restricted to the
  # preferences a read can apply: count, then handling, then timezone. `return=`
  # and friends are masked out for a non-mutation plan and never appear here.
  defp applied_tokens(count, handling, timezone) do
    [count, handling_token(handling), timezone_token(timezone)]
    |> Enum.reject(&is_nil/1)
  end

  defp handling_token(:strict), do: "handling=strict"
  defp handling_token(:lenient), do: "handling=lenient"
  defp handling_token(nil), do: nil

  defp timezone_token(nil), do: nil
  defp timezone_token(tz), do: "timezone=#{tz}"

  # Every `Prefer` token the request carries, in request order: `fromHeaders`
  # splits each header on ',' and strips the parts, preserving that order
  # (Preferences.hs#L152-L153).
  defp tokens(conn) do
    conn
    |> Plug.Conn.get_req_header("prefer")
    |> Enum.flat_map(&split/1)
  end

  defp split(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
