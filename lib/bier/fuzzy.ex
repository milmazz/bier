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

  ## Fidelity: score yes, retrieval no

  `score/2` is the function `fuzzyset` actually returns. `Fuzzy.fromList` builds
  a `defaultSet = emptySet 2 3 True`, and with `useLevenshtein = True` the gram
  cosine is only a candidate *pre-filter* — the returned score is replaced by
  `levenshteinNorm` over the lowercased strings, which is exactly what `score/2`
  computes.

  What is not reproduced is the retrieval stage that runs before that
  rescoring: upstream only ever scores candidates sharing an n-gram with the
  term, consults gram size 2 only when size 3 yields nothing, and truncates to
  the top 50 by cosine. All three make upstream *stricter*, so this module can
  offer a hint where upstream stays silent, never the reverse. The gap widens
  as `min_score` falls — it is negligible at the 0.75 table/procedure gate and
  reachable in principle at the 0.33 gate `no_rel_between_hint/3` uses.
  """

  # Longest `term` that is scored at all. Scoring is O(|term| · |candidate|) per
  # candidate and `term` is request-supplied — an unknown relation or routine
  # name straight off the URL — where upstream amortizes the work in a prebuilt
  # `FuzzySet`. PostgreSQL identifiers stop at NAMEDATALEN-1 = 63 bytes, so
  # nothing past this length can be the name the client meant; refusing to score
  # it bounds the per-404 cost without giving up a hint anyone would recognize
  # (#102). Upstream has no such cap.
  #
  # Caveat: this counts BYTES while `score/2` counts characters, so a
  # multi-byte name is refused well below 64 characters. Immaterial at the 0.75
  # gate — nothing that long clears it — but reachable at the 0.33 gate.
  @max_term_length 64

  @doc """
  The best-scoring candidate for `term`, or `nil` when none reaches `min_score`.

  Ties are broken by candidate name so the hint is stable across schema-cache
  reloads (a `FuzzySet` is likewise deterministic, but its insertion order is
  not something Bier's introspection guarantees).

  A `term` longer than #{@max_term_length} characters is not scored at all and
  yields `nil` — see the note above the constant.
  """
  @spec best_match(String.t(), [String.t()], float()) :: String.t() | nil
  def best_match(term, _candidates, _min_score)
      when byte_size(term) > @max_term_length,
      do: nil

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
