defmodule Bier.Fuzzy do
  @moduledoc """
  Approximate name matching for PostgREST's "Perhaps you meant …" hints.

  PostgREST keeps a `FuzzySet` per exposed schema (`SchemaCache.dbTablesFuzzyIndex`)
  and asks it for the single best match above a minimum score
  (`getFuzzyHint`, `Error.hs#L400`, `minScore = 0.75` for table and procedure
  names). The `fuzzyset` package scores a candidate by edit distance normalized
  against the longer of the two names, which is what `score/2` computes: an
  8-character name one edit away scores `1 - 1/8 = 0.875` and clears the
  threshold, while four edits away scores `0.5` and does not.

  Matching is case-insensitive, mirroring the normalization `FuzzySet` applies
  before indexing.
  """

  @doc """
  The best-scoring candidate for `term`, or `nil` when none reaches `min_score`.

  Ties are broken by candidate name so the hint is stable across schema-cache
  reloads (a `FuzzySet` is likewise deterministic, but its insertion order is
  not something Bier's introspection guarantees).
  """
  @spec best_match(String.t(), [String.t()], float()) :: String.t() | nil
  def best_match(term, candidates, min_score) do
    normalized = normalize(term)

    candidates
    |> Enum.sort()
    |> Enum.map(&{score(normalized, normalize(&1)), &1})
    |> Enum.filter(fn {score, _candidate} -> score >= min_score end)
    |> case do
      [] -> nil
      scored -> scored |> Enum.max_by(&elem(&1, 0)) |> elem(1)
    end
  end

  @doc """
  Similarity of two already-normalized names in `0.0..1.0`: one minus the edit
  distance over the length of the longer name.
  """
  @spec score(String.t(), String.t()) :: float()
  def score(a, b) do
    left = String.to_charlist(a)
    right = String.to_charlist(b)
    longest = max(length(left), length(right))

    if longest == 0 do
      1.0
    else
      1.0 - distance(left, right) / longest
    end
  end

  defp normalize(name), do: String.downcase(name)

  # Levenshtein distance, computed one row of the DP matrix at a time.
  defp distance(left, right) do
    first_row = Enum.to_list(0..length(right))

    left
    |> Enum.with_index(1)
    |> Enum.reduce(first_row, fn {char, row_index}, previous_row ->
      next_row(char, right, previous_row, row_index)
    end)
    |> List.last()
  end

  defp next_row(char, right, previous_row, row_index) do
    [diagonal | rest] = previous_row

    {row, _acc} =
      Enum.map_reduce(Enum.zip(right, rest), {row_index, diagonal}, fn {other, above},
                                                                       {left_cell, diagonal} ->
        cost = if char == other, do: 0, else: 1
        cell = Enum.min([left_cell + 1, above + 1, diagonal + cost])
        {cell, {cell, above}}
      end)

    [row_index | row]
  end
end
