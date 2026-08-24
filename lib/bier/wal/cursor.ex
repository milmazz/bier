defmodule Bier.Wal.Cursor do
  @moduledoc """
  Resume cursor for the WAL change feed: a commit LSN pair plus the event's
  index within its transaction, rendered as `X/Y.N` (Postgres's own hex LSN
  form, decimal sequence). Carried on every SSE frame as `id:` and accepted
  back via `Last-Event-ID`.
  """

  @type t :: {{non_neg_integer(), non_neg_integer()}, non_neg_integer()}

  @spec encode(t()) :: String.t()
  def encode({{hi, lo}, seq}),
    do:
      Integer.to_string(hi, 16) <>
        "/" <> Integer.to_string(lo, 16) <> "." <> Integer.to_string(seq)

  # A real LSN is two 32-bit halves and a transaction cannot hold more
  # events than `events_max_tx_events`, so anything larger was never a
  # cursor this server issued. `Last-Event-ID` is attacker-controlled: cap
  # the input before parsing so a multi-kilobyte digit string is rejected on
  # sight instead of being turned into a bignum first. A rejected cursor is
  # not an error to the client — the stream just starts at the live head.
  @max_lsn_half 0xFFFF_FFFF
  @max_encoded_bytes 64

  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(string) when is_binary(string) and byte_size(string) > @max_encoded_bytes, do: :error

  def parse(string) when is_binary(string) do
    with [lsn, seq] <- String.split(string, "."),
         [hi, lo] <- String.split(lsn, "/"),
         {hi, ""} when hi >= 0 and hi <= @max_lsn_half <- safe_hex(hi),
         {lo, ""} when lo >= 0 and lo <= @max_lsn_half <- safe_hex(lo),
         {seq, ""} when seq >= 0 <- safe_int(seq) do
      {:ok, {{hi, lo}, seq}}
    else
      _ -> :error
    end
  end

  # Erlang term order on {{hi, lo}, seq} is exactly commit order + sequence;
  # this wrapper exists to make call sites say what they mean.
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(a, a), do: :eq
  def compare(a, b) when a < b, do: :lt
  def compare(_a, _b), do: :gt

  # `Integer.parse/1` accepts a leading sign ("+5" -> {5, ""}), which would
  # make `+0/+1.+0` a synonym for a real cursor. Only bare digits are a
  # cursor this server could have issued.
  defp safe_hex(""), do: :error
  defp safe_hex(<<c, _::binary>>) when c in ~c"+-", do: :error
  defp safe_hex(s), do: Integer.parse(s, 16)

  defp safe_int(""), do: :error
  defp safe_int(<<c, _::binary>>) when c in ~c"+-", do: :error
  defp safe_int(s), do: Integer.parse(s)
end
