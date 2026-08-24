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

  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(string) when is_binary(string) do
    with [lsn, seq] <- String.split(string, "."),
         [hi, lo] <- String.split(lsn, "/"),
         {hi, ""} when hi >= 0 <- safe_hex(hi),
         {lo, ""} when lo >= 0 <- safe_hex(lo),
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

  defp safe_hex(""), do: :error
  defp safe_hex(s), do: Integer.parse(s, 16)

  defp safe_int(""), do: :error
  defp safe_int(s), do: Integer.parse(s)
end
