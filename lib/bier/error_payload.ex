defmodule Bier.ErrorPayload do
  @moduledoc """
  Serializes PostgREST's error envelope to its exact wire bytes.

  Two properties are pinned by the conformance suite and neither survives a
  plain map encode, so every error body goes through here.

  ## Key emission order is ALPHABETICAL

  `errorPayload` constructs the object as `[code, message, details, hint]`
  (`Error.hs#L69-L74`) but emits it with `JSON.encode` over an aeson `KeyMap`
  (`Error.hs#L66`). PostgREST pins `aeson >= 2.0.3 && < 2.3` and overrides
  neither `postgrest.cabal` nor `cabal.project` for aeson's `ordered-keymap`
  flag, whose default is `True` — so `KeyMap` is a `Data.Map.Strict` and the
  encoder walks its keys in ascending order. The bytes on the wire are therefore
  `{"code":…,"details":…,"hint":…,"message":…}`, compact, and NOT in
  construction order.

  Bier's default encoder (Elixir's stdlib `JSON`, via `Bier.json_library/0`)
  preserves neither: a map literal iterates in atom-creation order. The object
  is assembled here explicitly instead, one `Bier.json_library/0`-encoded value
  at a time.

  ## `client-error-verbosity`

  `toJsonPgrstError` (`Error.hs#L69-L78`) selects the members: `:verbose` (the
  default) emits `code`, `message`, `details` and `hint`; `:minimal` emits only
  `code` and `message` — `details` and `hint` are OMITTED entirely, not set to
  null. The verbosity is applied once, to every error the request pipeline
  produces (`App.hs#L154`), so it governs database errors as much as the
  `PGRSTxxx` ones, and `Response.hs` passes the same setting to the 416 body it
  builds inline while assembling a normal read response.
  """

  @minimal_keys ~w(code message)

  @typedoc "PostgREST's `client-error-verbosity` setting."
  @type verbosity :: String.t()

  @default_verbosity "verbose"

  @doc """
  The **effective** `client-error-verbosity` for an instance.

  Falls back to the default when the instance cannot be resolved — an error
  raised before the request was assigned to one still has to be rendered, and
  every caller wants the same fallback, so it lives here rather than being
  spelled at each call site.
  """
  @spec verbosity_for(atom() | nil) :: verbosity()
  def verbosity_for(nil), do: @default_verbosity

  def verbosity_for(instance) do
    case Bier.Registry.fetch_config(instance) do
      {:ok, %{client_error_verbosity: verbosity}} -> verbosity
      _other -> @default_verbosity
    end
  end

  @doc """
  Encode an error envelope (a map with atom or string keys) into the JSON text
  PostgREST would put on the wire.
  """
  @spec encode(map(), verbosity()) :: String.t()
  def encode(body, verbosity) do
    body
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> filter(verbosity)
    |> Enum.sort_by(&elem(&1, 0))
    |> encode_object()
  end

  defp filter(pairs, "minimal"), do: Enum.filter(pairs, fn {key, _v} -> key in @minimal_keys end)
  defp filter(pairs, _verbose), do: pairs

  defp encode_object(pairs) do
    json = Bier.json_library()

    members =
      Enum.map_intersperse(pairs, ",", fn {key, value} ->
        [json.encode_to_iodata!(key), ?:, json.encode_to_iodata!(sanitize(value))]
      end)

    IO.iodata_to_binary([?{, members, ?}])
  end

  # `details`/`message`/`hint` routinely echo attacker-controlled text (an
  # unknown channel/table/column name, a malformed relation) straight from the
  # request. `URI.decode_www_form/1` never validates UTF-8 — an invalid
  # percent-escape (e.g. `%e2%28%a1`) decodes to a binary that survives every
  # step up to here, where the stdlib `JSON` encoder rejects it outright
  # (`{:invalid_byte, _}`), turning the response meant to report the original
  # error into an unhandled 500. Scrub rather than trust it.
  defp sanitize(value) when is_binary(value) do
    if String.valid?(value), do: value, else: scrub_utf8(value, [])
  end

  defp sanitize(value), do: value

  defp scrub_utf8(binary, acc) do
    case :unicode.characters_to_binary(binary) do
      valid when is_binary(valid) ->
        IO.iodata_to_binary(Enum.reverse([valid | acc]))

      {tag, good, <<_bad, rest::binary>>} when tag in [:error, :incomplete] ->
        scrub_utf8(rest, ["�", good | acc])

      {tag, good, <<>>} when tag in [:error, :incomplete] ->
        IO.iodata_to_binary(Enum.reverse([good | acc]))
    end
  end
end
