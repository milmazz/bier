defmodule Bier.ErrorPayloadTest do
  @moduledoc """
  `Bier.ErrorPayload.encode/2` is the single choke point every error response
  serializes through (see its moduledoc). Covers the wire-byte pins (key
  order, verbosity filtering) plus #142: a `details`/`message`/`hint` value
  can carry client-controlled text taken straight from the request, and
  nothing on the way here validates UTF-8 — neither `URI.decode_www_form/1`
  for a percent-escape nor the CSV column parser for a request body — so the
  value can reach the stdlib `JSON` encoder as a binary it rejects outright.
  """
  use ExUnit.Case, async: true

  alias Bier.ErrorPayload

  # `URI.decode_www_form("%e2%28%a1")` — a malformed percent-escape that
  # decodes to a byte sequence with no valid UTF-8 interpretation.
  @invalid <<226, 40, 161>>

  describe "encode/2" do
    test "emits keys in alphabetical order regardless of map construction order" do
      body = %{message: "boom", code: "PGRST100", hint: nil, details: "why"}

      assert ErrorPayload.encode(body, "verbose") ==
               ~s({"code":"PGRST100","details":"why","hint":null,"message":"boom"})
    end

    test "minimal verbosity omits details and hint entirely" do
      body = %{code: "PGRST100", message: "boom", details: "why", hint: "try again"}

      assert ErrorPayload.encode(body, "minimal") == ~s({"code":"PGRST100","message":"boom"})
    end

    test "a value that is valid UTF-8 passes through untouched" do
      body = %{code: "BIER001", message: "m", details: "café", hint: nil}

      assert ErrorPayload.encode(body, "verbose") ==
               ~s({"code":"BIER001","details":"café","hint":null,"message":"m"})
    end

    test "an invalid-UTF-8 value is scrubbed instead of crashing the encoder" do
      body = %{code: "BIER001", message: "Unknown event channel", details: @invalid, hint: nil}

      decoded = decode(ErrorPayload.encode(body, "verbose"))

      assert String.valid?(decoded["details"])
      assert decoded["code"] == "BIER001"
    end

    test "invalid UTF-8 embedded in an otherwise-valid string is scrubbed in place" do
      invalid = "Channel '" <> @invalid <> "' is not exposed"
      body = %{code: "BIER001", message: "m", details: invalid, hint: nil}

      decoded = decode(ErrorPayload.encode(body, "verbose"))

      assert String.valid?(decoded["details"])
      assert decoded["details"] =~ "Channel '"
      assert decoded["details"] =~ "' is not exposed"
    end

    test "non-binary values (nil, integers) are left untouched" do
      body = %{code: "PGRST103", message: "m", details: 42, hint: nil}

      assert ErrorPayload.encode(body, "verbose") ==
               ~s({"code":"PGRST103","details":42,"hint":null,"message":"m"})
    end

    test "a truncated trailing sequence is scrubbed" do
      # A lead byte with its continuation bytes cut off decodes as
      # `:incomplete` rather than `:error` — a distinct code path from the
      # `<<226, 40, 161>>` case, and the shape a size-truncated value takes.
      body = %{code: "BIER001", message: "m", details: <<"caf", 0xC3>>, hint: nil}

      decoded = decode(ErrorPayload.encode(body, "verbose"))

      assert String.valid?(decoded["details"])
      assert decoded["details"] =~ "caf"
    end

    test "one U+FFFD replaces each invalid sequence, not each invalid byte" do
      # The Unicode maximal-subpart rule, which is what `String.replace_invalid/1`
      # implements and what upstream's lenient decoding does. Pinned because the
      # obvious hand-rolled alternative (walk byte by byte) differs here, and
      # differs quadratically in cost — see the moduledoc note.
      body = %{code: "BIER001", message: "m", details: <<0xF0, 0x9F, 0x92>>, hint: nil}

      assert decode(ErrorPayload.encode(body, "verbose"))["details"] == "\uFFFD"
    end

    test "invalid UTF-8 nested inside a structured details is scrubbed" do
      # PGRST201 (`Bier.Embed.ambiguous_error/3`) builds `details` as a list of
      # maps, so the scrub has to reach inside containers, not just scalars.
      body = %{
        code: "PGRST201",
        message: "m",
        details: [%{"relationship" => "a", "embedding" => "items with " <> @invalid}],
        hint: nil
      }

      decoded = decode(ErrorPayload.encode(body, "verbose"))
      [entry] = decoded["details"]

      assert String.valid?(entry["embedding"])
      assert entry["embedding"] =~ "items with "
    end

    test "an invalid-UTF-8 key is scrubbed too" do
      body = %{("det" <> @invalid) => "v", code: "BIER001", message: "m"}

      assert body |> ErrorPayload.encode("verbose") |> String.valid?()
    end

    test "scrubbing a large invalid value stays linear" do
      # Guards the CPU-exhaustion regression: an uncapped request body can put
      # ~300 KB of invalid bytes into an error message. `String.replace_invalid/1`
      # does that in single-digit milliseconds; the byte-at-a-time loop it
      # replaced took ~15 s. The bound is loose enough not to flake under a
      # loaded suite while still failing outright on quadratic behaviour.
      body = %{code: "PGRST204", message: :binary.copy(<<0x80>>, 300_000), hint: nil}

      {micros, json} = :timer.tc(fn -> ErrorPayload.encode(body, "verbose") end)

      assert String.valid?(json)
      assert micros < 2_000_000
    end
  end

  describe "the choke point over real HTTP" do
    setup do
      %{base: Bier.ConformanceServer.base_url()}
    end

    test "invalid UTF-8 in a CSV header row answers PGRST204, not a raw 500", %{base: base} do
      # The client-reachable variant of #142, and the one that needs no raw
      # socket: a `text/csv` body's column names are taken from the request
      # bytes verbatim (`Bier.Mutation.parse_csv/1`) and echoed into the
      # PGRST204 message, so any endpoint that quotes decoded request data —
      # not just `/events` — reaches the encoder with unvalidated bytes.
      resp =
        Req.post!(base <> "/projects",
          headers: [{"content-type", "text/csv"}],
          body: "id,na" <> @invalid <> "me\n1,x",
          raw: true,
          compressed: false,
          retry: false
        )

      assert resp.status == 400
      assert String.valid?(resp.body)
      assert decode(resp.body)["code"] == "PGRST204"
    end
  end

  defp decode(json), do: Bier.json_library().decode!(json)
end
