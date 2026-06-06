defmodule Bier.Preferences do
  @moduledoc """
  Parsing and validation of the `Prefer` request header for the **read** path
  (the write path's `Prefer` handling lives in `Bier.Mutation`).

  Mirrors PostgREST's PreferencesSpec semantics:

    * recognized preference keys are `handling`, `timezone`, `max-affected`,
      `return`, `resolution`, `count`, `missing`, `tx`;
    * `handling=strict` rejects the whole request (400 `PGRST122`) when ANY
      supplied preference is invalid — an unrecognized token, or a `timezone`
      whose value is not a valid Postgres time zone name. The error `details`
      lists the offending tokens verbatim, comma-separated;
    * `handling=lenient` (or no handling) silently ignores invalid preferences;
    * an applied `timezone=<name>` shifts `timestamptz` rendering and is echoed in
      `Preference-Applied`.

  `parse_read/2` runs the (cheap) timezone validity check against the given
  Postgrex pool so the strict path can reject an invalid zone before any read.
  """

  @recognized_keys ~w(handling timezone max-affected return resolution count missing tx)

  @doc """
  Parse the connection's `Prefer` header for a read.

  Returns:

    * `{:ok, %{timezone: tz | nil, applied: [token]}}` — the timezone to apply
      (nil when none/invalid-but-lenient) and the tokens to echo in
      `Preference-Applied`.
    * `{:error, {:invalid_prefs, details}}` — `handling=strict` with one or more
      invalid preferences; `details` is the `"Invalid preferences: a, b"` string.
  """
  def parse_read(conn, pool) do
    tokens =
      conn
      |> Plug.Conn.get_req_header("prefer")
      |> Enum.flat_map(&split/1)

    handling = handling(tokens)
    timezone = timezone_value(tokens)

    invalid = invalid_tokens(tokens, timezone, pool)

    cond do
      handling == :strict and invalid != [] ->
        {:error, {:invalid_prefs, "Invalid preferences: " <> Enum.join(invalid, ", ")}}

      true ->
        # A valid timezone is applied (and echoed); an invalid one under lenient
        # handling is dropped.
        applied_tz = if timezone && valid_timezone?(timezone, pool), do: timezone, else: nil

        {:ok,
         %{
           timezone: applied_tz,
           applied: applied_tokens(handling, applied_tz)
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

  # Tokens that make a `handling=strict` request invalid: any unrecognized token,
  # plus a `timezone` whose value is not a real Postgres time zone.
  defp invalid_tokens(tokens, timezone, pool) do
    unknown =
      Enum.reject(tokens, fn token ->
        token
        |> String.split("=", parts: 2)
        |> hd()
        |> Kernel.in(@recognized_keys)
      end)

    bad_tz =
      if timezone && not valid_timezone?(timezone, pool), do: ["timezone=#{timezone}"], else: []

    unknown ++ bad_tz
  end

  # Echo, in PostgREST's canonical order: handling, then timezone. (For reads
  # only timezone is applied; handling is echoed only alongside an applied
  # preference per the spec's strict-timezone case, but the single-timezone read
  # case echoes just `timezone=...`.)
  defp applied_tokens(_handling, nil), do: []
  defp applied_tokens(_handling, tz), do: ["timezone=#{tz}"]

  defp valid_timezone?(tz, pool) do
    case Postgrex.query(pool, "SELECT EXISTS(SELECT 1 FROM pg_timezone_names WHERE name = $1)", [
           tz
         ]) do
      {:ok, %Postgrex.Result{rows: [[exists]]}} -> exists
      _ -> false
    end
  end

  defp split(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
