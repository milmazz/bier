defmodule Bier.Preferences do
  @moduledoc """
  Parsing and validation of the `Prefer` request header for the **read** path
  (the write path's `Prefer` handling lives in `Bier.Mutation`).

  Mirrors PostgREST v16.0's `ApiRequest.Preferences` semantics:

    * recognized preference keys are `handling`, `timezone`, `max-affected`,
      `return`, `resolution`, `count`, `missing`, `tx`;
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
      canonical order (`handling` before `timezone`), never in request order.

  Numeric UTC offsets (`+05:30`, `-4`) are consequently valid too: they are not
  members of `pg_timezone_names` but PostgreSQL accepts them as a `TimeZone`,
  and the echo carries the raw preference token rather than a normalized zone
  name.
  """

  @recognized_keys ~w(handling timezone max-affected return resolution count missing tx)

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
    tokens =
      conn
      |> Plug.Conn.get_req_header("prefer")
      |> Enum.flat_map(&split/1)

    handling = handling(tokens)
    invalid = invalid_tokens(tokens)

    if handling == :strict and invalid != [] do
      {:error, {:invalid_prefs, "Invalid preferences: " <> Enum.join(invalid, ", ")}}
    else
      timezone = timezone_value(tokens)

      {:ok,
       %{
         timezone: timezone,
         applied: applied_tokens(handling, timezone)
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

  # Tokens that make a `handling=strict` request invalid: any token whose key is
  # not a recognized preference. A `timezone` token is always recognized in
  # v16.0 regardless of its value — PostgreSQL, not PostgREST, judges it.
  defp invalid_tokens(tokens) do
    Enum.reject(tokens, fn token ->
      token
      |> String.split("=", parts: 2)
      |> hd()
      |> Kernel.in(@recognized_keys)
    end)
  end

  # Echo, in PostgREST's canonical order: handling, then timezone. Only
  # preferences the read path actually applies are echoed, so `return=` and
  # friends never appear here.
  defp applied_tokens(handling, timezone) do
    [handling_token(handling), timezone_token(timezone)]
    |> Enum.reject(&is_nil/1)
  end

  defp handling_token(:strict), do: "handling=strict"
  defp handling_token(:lenient), do: "handling=lenient"
  defp handling_token(nil), do: nil

  defp timezone_token(nil), do: nil
  defp timezone_token(tz), do: "timezone=#{tz}"

  defp split(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
