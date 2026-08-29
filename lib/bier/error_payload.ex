defmodule Bier.ErrorPayload do
  @moduledoc """
  Serializes PostgREST's error envelope to its exact wire bytes.

  Two properties are pinned by the conformance suite and neither survives a
  plain map encode, so every error body goes through here. A third guarantee —
  the bytes handed to the encoder are always valid UTF-8 — is enforced here for
  the same reason: this is the one place every error body passes.

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

  ## Values are scrubbed to valid UTF-8

  `details`/`message`/`hint` routinely echo client-controlled text — an unknown
  channel/table/column name, a malformed relation — decoded straight from the
  request. Neither `URI.decode_www_form/1` nor the CSV column parser validates
  UTF-8, so those values can carry byte sequences the stdlib `JSON` encoder
  rejects outright (`{:invalid_byte, _}`), which would turn the response meant
  to report the *original* error into an unhandled 500. Every key and every
  value is passed through `String.replace_invalid/1` first, so an invalid
  sequence becomes U+FFFD and the original error still gets reported with its
  own status. Valid input is returned unchanged, byte for byte.
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
        [json.encode_to_iodata!(sanitize(key)), ?:, json.encode_to_iodata!(sanitize(value))]
      end)

    IO.iodata_to_binary([?{, members, ?}])
  end

  # See the "Values are scrubbed to valid UTF-8" moduledoc section. The valid
  # case — every error body Bier itself produces — returns the same binary and
  # allocates nothing; only a value carrying client bytes pays for a rewrite.
  # `String.replace_invalid/1` is linear and does the maximal-subpart
  # substitution Unicode specifies (one U+FFFD per invalid *sequence*, not per
  # byte); a hand-rolled loop over `:unicode.characters_to_binary/1` is
  # quadratic in the number of bad bytes, which an uncapped request body turns
  # into a CPU-exhaustion vector.
  defp sanitize(value) when is_binary(value) do
    if String.valid?(value), do: value, else: String.replace_invalid(value)
  end

  # `details` is not always a scalar: PGRST201 builds it as a list of maps
  # (`Bier.Embed.ambiguous_error/3`), so the walk has to reach inside
  # containers or the guarantee above would be silently partial. Structs are
  # left whole — they carry their own encoder.
  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)

  defp sanitize(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, val} -> {sanitize(key), sanitize(val)} end)

  defp sanitize(value), do: value
end
