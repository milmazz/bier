defmodule Bier.ErrorPayloadTest do
  @moduledoc """
  `Bier.ErrorPayload.encode/2` is the single choke point every error response
  serializes through (see its moduledoc). Covers the wire-byte pins (key
  order, verbosity filtering) plus #142: a `details`/`message`/`hint` value
  can carry attacker-controlled text decoded straight from the request, and
  `URI.decode_www_form/1` never validates UTF-8 — an invalid percent-escape
  survives decoding as a binary the stdlib `JSON` encoder rejects outright.
  """
  use ExUnit.Case, async: true

  alias Bier.ErrorPayload

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
      # `URI.decode_www_form("%e2%28%a1")` — a malformed percent-escape that
      # decodes to a byte sequence with no valid UTF-8 interpretation.
      invalid = <<226, 40, 161>>
      body = %{code: "BIER001", message: "Unknown event channel", details: invalid, hint: nil}

      decoded = decode(ErrorPayload.encode(body, "verbose"))

      assert String.valid?(decoded["details"])
      assert decoded["code"] == "BIER001"
    end

    test "invalid UTF-8 embedded in an otherwise-valid string is scrubbed in place" do
      invalid = "Channel '" <> <<226, 40, 161>> <> "' is not exposed"
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
  end

  defp decode(json), do: Bier.json_library().decode!(json)
end
