# Bier conformance spec

This directory is the **behavioral specification** Bier targets: a black-box,
forge-neutral model of how [PostgREST](https://postgrest.org) responds to HTTP
requests, distilled from PostgREST's own public behavior and test suite.

Bier aims to serve a RESTful API generated on-the-fly from PostgreSQL
introspection, "heavily inspired by PostgREST." This `spec/` tree pins down what
that compatibility means, case by case, so it can be checked automatically.

## Pinned version

Everything here targets **PostgREST v16.0** (docs:
[postgrest.org/en/v16](https://postgrest.org/en/v16/)). Every conformance case
carries a `source:` URL pinned to the `v16.0` git tag with a `#L<line>` anchor,
fetchable via `raw.githubusercontent.com`. All **762** cases are pinned to
`v16.0` — verified on disk this pass by parsing each case's `source:` value and
extracting its tag (`{'v16.0': 762}`, no other value). Sweeping every PostgREST
URL across the 17 area models plus all 762 cases (**779** files, **every one**
carrying at least one citation) with a prefix-aware pattern finds **2089**
`raw…/v16.0/` links plus **3** `github.com/…/blob/v16.0/` links — **2092**
citations at a single tag — and **exactly one** URL at any other tag, described
below. When bumping the target version, re-pin the sources and re-run the review
pass.

> **`source:` is not the only citation key, and a pin bump that sweeps only
> `source:` will leave the tree half re-pinned.** Area models cite through
> **`source_url:`** in every `gaps:` entry. Walking both keys structurally over
> the models and the cases finds **1266** `source:` fields + **144**
> `source_url:` fields = **1410**, histogram `{'v16.0': 1410}`, zero off-pin —
> and the 144 are exactly where the tree records *unmodelled* behavior, so they
> are the citations a stale pin would damage most quietly.
> `domain_representations.yaml` alone carries 10.

> **The raw-link count grew 2054 → 2092 (+38) while the case count grew by
> sixteen, and this is the first pass whose growth can be attributed exactly.**
> Measured file by file against HEAD: the sixteen new
> `domain_representations` cases (**1821–1836**) contribute exactly **16** — one
> `source:` each, none carrying a URL in its `notes:` — the three rewritten cases
> (1811–1813) contribute **0**, and the whole remaining **+22** is inside
> `spec/domain_representations.yaml`, which went **28 → 50** links as its `gaps:`
> key went 5 → 10 entries.
>
> **That is the mirror image of the two passes before it** (+20 on six cases,
> +45 on five), whose growth lived inside case `notes:`. Case **1821** shows why
> the case half stayed flat here: its `notes:` argues four separate upstream
> facts — the `OpQuant` vs `Op` arms of `SqlFragment.hs#L388`/`#L384`, the
> `Error.hs#L584-L586` 42883→404 mapping, upstream's PG-version body branch at
> `QuerySpec.hs#L1657-L1665`, and `SpecHelper.hs#L139`'s empty
> `configDbExtraSearchPath` — using **bare `file#Lnnn` anchors rather than
> URLs**, so a URL sweep sees one citation where the argument rests on five.
> **`case.schema.json` allows exactly one `source:`**, and the overflow goes
> either into `notes:` URLs (counted) or bare anchors (uncounted). Do not read
> link growth as case growth in either direction.

> **The `blob/v16.0` count is THREE, re-derived again this pass rather than
> carried over.** Enumerating *every* `github.com/PostgREST/postgrest…` URL in the
> sweep scope (a host match, no tag pattern at all) returns exactly **four** — three
> `blob/v16.0` (`spec/domain_representations.yaml:84` and `spec/select.yaml:27`,
> both prose notes about URL shape rather than citations, plus
> **`spec/rpc.yaml:564`**, the *re-pinned* URL inside the now-RESOLVED provenance
> gap entry) and the single `blob/v14.12` described below. **The
> `domain_representations.yaml` line moved 44 → 84** when its re-sync header grew;
> the URL itself is unchanged. Every other citation in
> the tree uses the `raw.githubusercontent.com` host. The still-earlier "**71**
> `blob/v16.0` links" figure stays retired — do not carry it forward. The
> invariant all three numbers were reaching for holds under every measurement:
> **one tag among citations, zero exceptions.**

> **A prior sweep of this file under-counted the raw links too, and the cause is
> worth knowing.** It reported 1984 `raw…/v16.0/` + 1 blob instead of 1986 + 3,
> because its regex required a leading `//` and so skipped every scheme-less URL.
> That is the **third** distinct sweep-pattern defect this tree has recorded,
> after the `blob/` infix and the `https://` anchor. Match
> `(?:https?://)?(raw\.githubusercontent\.com|github\.com)/PostgREST/postgrest/(?:raw/|blob/|tree/)?<tag>`
> and nothing narrower.

> **`case.schema.json` does not enforce the pin.** Its `source` pattern is
> `^https://raw\.githubusercontent\.com/PostgREST/postgrest/.+#L[0-9]+$` — the
> `.+` matches *any* tag, so a case pinned to `v14.12` still validates. Only the
> URL sweep above catches stale pins; a green schema run does not. This was
> proved by negative control in an earlier pass and the pattern has not changed
> since.

> **Match the URL prefix, not just the tag.** A naive `grep -v 'postgrest/v16\.0/'`
> reports dozens of false stale hits, because
> `github.com/PostgREST/postgrest/blob/v16.0/…` puts `blob/` between the repo
> and the tag. Sweep with a prefix-aware pattern
> (`postgrest/(raw/|blob/|tree/)?<tag>`) or the count is wrong. Do not anchor on
> `https://` either — several in-scope URLs are written scheme-less.

> **The one remaining `v14.12` URL in the audited set is now CORRECT, and the
> steady state is `v14.12: 1` forever.** It sits at **`spec/rpc.yaml:574`** (it
> was at `:564` until commit `75388d6` rewrote the entry above it):
> `https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql`,
> inside an `operator_action` gap entry whose whole purpose was to *report* that
> `conformance/fixtures/rpc.sql#L15` carried that stale provenance pin.
> **Both halves of that condition are now closed.** Commit **`6b25f05`**
> re-pinned the fixture: `fixtures/rpc.sql:15` reads
> `blob/v16.0/test/spec/fixtures/schema.sql` followed by "Re-pinned v14.12 ->
> v16.0 after verifying all 23 vendored routines…", and `rpc.sql` carries **zero**
> `v14.12` URLs. Commit **`75388d6`** then closed the documentation half, rewriting
> the entry to open "RESOLVED 2026-08-09 (commit 6b25f05) — kept as a record, no
> action left" while **deliberately retaining the original finding verbatim,
> quoted URL included**, for provenance.
>
> **So do not re-open this as drift, and do not delete the quotation to make a
> sweep read zero.** A prefix-aware sweep will report exactly one `v14.12` URL
> permanently; the machine verification scores **0** stale pins for an unrelated
> reason (its pattern matches only `raw.githubusercontent.com`), so the two agree
> by accident rather than by construction. `COVERAGE.md` → follow-up 24 is
> **CLOSED**, the first follow-up in this tree to close end to end.

> **`v14.12` in prose is not a stale pin.** **121** bare `v14.12` occurrences
> remain across the 17 area model files, re-derived at the 762-case state
> (`url_grammar.md` 15,
> `pagination.yaml` 14, `errors.yaml` 13, `observability.yaml` 12, `auth.yaml`
> 10, `config.yaml` 9, **`rpc.yaml` 7**, `filters.yaml` / `ordering.yaml` 6 each,
> `content_negotiation.yaml` / `headers.yaml` / `openapi.yaml` 5 each,
> `mutations.yaml` 4, `select.yaml` 4,
> **`domain_representations.yaml` 3**, `operators.yaml` 2,
> `representations.yaml` 1), plus **27**
> occurrences across **26** case files (unchanged — none of the sixteen new cases
> mentions the old pin). These are counted by *occurrence*, not by
> line. Sampling them shows deliberate
> v14.12→v16.0 change notes ("the block is byte-identical to v14.12, only the
> `src/library/` path and line numbers move").
>
> **The +2 this pass is `domain_representations.yaml` (1 → 3), and it is the
> TENTH consecutive instance of the same pattern: a flat "nothing changed"
> becoming a checkable one.** At HEAD the file carried a single occurrence. It
> now opens with a `v14.12 -> v16.0 re-sync notes (the diff, for the record)`
> block that names *what* was compared — the `src/PostgREST/…` →
> `src/library/PostgREST/…` tree move, the byte-identical `dataRepresentations`
> catalog query, the unchanged `datarep_*` / `devil_int` / `evil_friends*`
> fixture DDL, the unchanged docs page — and *what actually differs*: **three
> upstream requests gained an explicit `&order=id` between the pins**, which is
> why cases **1807**, **1816** and **1818** each carry one. That is a real
> behavioral delta a "no change in this area" header would have buried, and it is
> the only one the v16.0 re-sync found in this area. **The occurrence count is
> the only trace the improvement leaves**, which is why this note keeps counting
> them.
>
> **Retained, because it describes the previous pass:** the +2 then was
> `openapi.yaml` (3 → 5), also entirely in that file's re-sync header, which went
> from "no behavior change in this area." to a statement of the diff's *scope*
> (`git diff v14.12..v16.0 -- test/spec/Feature/OpenApi/…`) and how the configs
> compare.
>
> **CORRECTION, and it is a correction to this document rather than to the tree:
> `rpc.yaml` holds SEVEN occurrences, not six, and always did.** The previous
> revision recorded it as 6 and inferred a "7 → 6" movement from commit
> `75388d6`. Re-counting by occurrence on disk this pass — `rpc.yaml` lines 20
> (×1), 21 (×1), 44, 444, 497, 573, 574 — gives **7**, and `rpc.yaml` is
> **unmodified** in `git status`, so nothing moved. The tree total is therefore
> **117**, not 116, and the file-count line 20–21 is the trap: two occurrences on
> two adjacent lines, easy to collapse into one when counting by line. **Count by
> occurrence and say which you counted.**
>
> **The lesson the retired "7 → 6" reading was reaching for still stands, and
> `representations.yaml` is its better example.** That file held at **1** while
> having its one occurrence **rewritten**: its re-sync note used to assert
> "no behavior in this area changed" flatly, and now says so "re-verified by
> diffing both pins rather than carried over", then itemizes what *did* move (the
> four cited Feature specs shifted 1–3 lines from a harness signature change,
> `SpecWith ((), Application)` → `SpecWithConfig`, plus a further 7-line shift on
> every `InsertSpec.hs` anchor after `#L554-L559`, where the generated-column
> error block dropped its `actualPgVersion < pgVersion140` branch) and names the
> one `Preferences.hs` behavior change in its window — `Prefer: timezone` losing
> the `TimezoneNames` schema-cache check — **together with why it is out of
> scope**: it does not touch `return=`. **That is the shape a "nothing changed"
> note should have.** The count did not move; the claim's checkability did.
> **Occurrence counts move for editorial reasons — and, as this correction shows,
> for counting-method reasons. Never read them as research.**
> (This count deliberately excludes `README.md`, `COVERAGE.md` and
> `conformance/INDEX.md`, which the synthesis phase rewrites; counting files
> against themselves is not a measurement.)
>
> **Five** such notes have been **corrected** rather than carried forward: case
> 1029's claim that the query parser was "byte-identical between the pins";
> case 1016's claim that no v16.0 Feature-spec line existed for the PUT-`limit`
> rule; `pagination.yaml`'s "no pagination behavior changed between the pins",
> narrowed to "no *asserted* behavior changed"; `observability.yaml`'s claim that
> the OPTIONS Server-Timing "subset" was unchanged from v14.12 (the *unchanged*
> half was true, the *subset* half was false at **both** pins, and `lib/` had
> implemented it); and `operators.yaml`'s claim that cases 10200–10219 "closed
> everything in the *existed at both pins, never modeled* bucket" — they had not.
> Treat comparative prose as a claim to re-verify, not as settled fact.
>
> **The rpc pass produced no sixth correction, and that is not the same as
> producing none.** Its audit returned **five** findings of a different species:
> not a false "nothing changed" note, but **no note at all** on five behaviors
> that existed at both pins — including two whole H2 sections of the *Functions
> as RPC* docs page. Read "nothing changed between the pins" as a claim about
> *change*, never as a claim about *coverage*, and read the absence of a note as
> no claim at all.
>
> **The mutations pass supplies the sixth, and it is a third species again: a
> claim withdrawn for having no citation at all.** `mutations.yaml`'s
> `columns_param` section previously asserted that `?columns=` applies to **PUT**.
> The re-sync found nothing at v16.0 that says so — every `columns=` occurrence in
> `UpsertSpec.hs` is a POST (L108/L121/L134, L236/L248/L260), the docs reference
> `specify_columns` only from Insert (`tables_views.rst#L565`) and Update
> (`#L607`), and the PUT subsection says the *opposite*: "All the columns must be
> specified in the request body, including the primary key columns" (`#L689`).
> The claim was **withdrawn rather than approximated**, and the section header now
> reads `applies_to: [POST, PATCH]`. Note the failure mode: unlike the five
> comparative-prose corrections, this one was never a statement about a *version*
> — it was an uncited rule that no sweep in this document can detect. **A pin
> sweep checks tags; nothing here checks whether a modelled rule has a source at
> all.**
>
> **The representations pass supplies a SEVENTH species, and it is the subtlest
> so far: a citation that is real, fetchable, correctly pinned, and proves a
> NARROWER claim than the model attaches to it.** `representations.yaml` cited
> `InsertSpec.hs#L745` for "a POST without `return=headers-only` carries no
> `Location`". That line exists and asserts exactly that — but it sits under
> `describe "Inserting into VIEWs"` and posts to `/compound_pk_view`, so it
> witnesses the rule **on a view only**. The model now cites `#L157` (the
> no-`Prefer` it-block on the `projects` TABLE) and `#L99`
> (`return=representation`), and case **1309** was rewritten with it. **Note what
> this defeats**: the pin sweep passes (right tag), schema validation passes
> (right shape), and even an adversarial "does the cited line support the claim?"
> read passes, because the line supports *a* claim. Only reading the enclosing
> `describe` catches it. **Verify the block, not the line.**

> **The content_negotiation pass supplies an EIGHTH species, and it is the first
> that is not about a `source:` at all: a defective FIXTURE transcription that
> made a case's assertion unreachable.** `fixtures.sql` declared
> `test.unnamed_bytea_param(bytea) RETURNS bytea`; upstream declares it
> `returns "application/octet-stream"` — the mime-named **DOMAIN**
> (`test/spec/fixtures/schema.sql#L2372`). Since a routine's **return type** is
> the only thing that registers an octet-stream handler
> (`SchemaCache.hs#L1016` ships json/csv/geo+json/`*/*` and nothing else), case
> **1622**'s expected 200 could never have been produced by a faithful
> implementation — it would have negotiated to 406/PGRST107. **Every mechanical
> check in this tree passed on it**: the case validated, its pin was correct, its
> citation was real, its filename matched its id — *and the case passed*, because
> `lib/bier/rpc.ex:288` offers octet-stream for any scalar RPC result regardless
> of return type. A green case over a wrong fixture is indistinguishable from a
> green case over a right one. `content_negotiation.yaml` now carries a
> **`fixture_notes:`** key recording, per object, exactly which fixture property
> each case depends on and what breaks if it changes — the first such key in the
> tree, and worth copying into every area whose cases depend on a *declaration*
> rather than on seed data.
>
> **The same pass also weakened two claims to what their citations support**,
> which is the ordinary form of this defect: "negotiateContent's body is
> **byte-identical** to v14.12's" became identical *modulo whitespace* (v16.0
> re-aligned the `case` alternatives), and "**NEW in v16.0**: the JSON plan
> includes a Query Identifier field" became "upstream **added a test** at v16.0"
> — the field comes from PostgreSQL's `EXPLAIN (VERBOSE, FORMAT JSON)` under
> `compute_query_id`, so the old wording both over-claimed and contradicted the
> model's own `version_delta.behavior_changes: []`. **"Byte-identical" is a
> falsifiable claim; prefer the weaker true one.**

> **Fixture provenance comments are mostly still on the old pin, and the set did
> not shrink this pass.** **Six** files under `conformance/fixtures/` carry **43**
> `v14.12` URLs in `--` provenance comments (re-counted on disk: `ordering.sql`
> 27, `errors.sql` 5, `auth.sql` 4, `mutations.sql` 3, `config.sql` 2,
> `filters.sql` 2 — count URLs, not bare occurrences; the same files hold a
> further 31 `v14.12` mentions in prose). Two fragments have been re-pinned to
> v16.0: `observability.sql` (7 → **0**, by the observability re-sync — a
> comment-only change with every anchored line number verified unchanged across
> the pins) and `rpc.sql` (1 → **0**, by commit `6b25f05`, after verifying all 23
> vendored routines are still defined at v16.0 with unchanged signatures). **Two
> precedents and still no rule** — whether the remaining six get the same
> treatment is an open decision (`COVERAGE.md` → follow-up 14).
> **The representations and openapi passes both had nothing to decline**:
> `fixtures/representations.sql` and `fixtures/openapi.sql` each carry **zero**
> `v14.12` URLs (`openapi.sql` holds two bare `v14.12` mentions in prose, which
> is a different thing). So the total held at 43 for a **third**
> consecutive pass — which is *not* evidence the drift is stabilising, only that
> the fragments still carrying it have not been touched by a re-sync since the
> practice began (`ordering.sql` alone holds 27 of the 43). Nothing under
> `conformance/fixtures/` and no line of `conformance/fixtures.sql` is modified in
> `git status` this pass: the openapi re-sync added **no fixture object**, the
> first re-sync to leave `fixtures.sql` untouched since content_negotiation's
> octet-stream correction. Its five `fixture_notes:` entries are the record it
> wrote *instead* — five declarations its cases depend on and did not change.
> These files are
> historical provenance and explicitly non-authoritative (the live artifact is
> `conformance/fixtures.sql`), so the re-syncs otherwise leave them alone — but
> do not read "single tag" above as covering `*.sql`.

> **v16 source-layout note.** v16 moved the library sources from
> `src/PostgREST/…` to `src/library/PostgREST/…` (a new `src/executable/` tree
> holds the CLI). Source anchors into implementation files therefore carry the
> `src/library/` prefix; the old `src/PostgREST/` anchors are stale *paths*, not
> merely stale line numbers.

## What's here

```
spec/
├── README.md                  # this file
├── COVERAGE.md                # docs-page -> covering case ids; gaps + verification
├── case.schema.json           # JSON Schema for a single conformance case
├── <area>.yaml | url_grammar.md   # 17 per-area behavior models (the "why")
└── conformance/
    ├── INDEX.md               # area <-> id band <-> fixture cross-reference
    ├── cases/NNNN_<slug>.yaml # 762 conformance cases (the "what", machine-checkable)
    ├── fixtures.sql           # the authoritative merged DDL+seed set
    ├── fixtures_local.sql     # human-owned harness supplement
    └── fixtures/              # per-area fragments + write-channel deltas (see its README)
```

There are two layers:

1. **Area behavior models** — one file per feature area
   (`url_grammar.md` plus 16 `.yaml` files: `operators`, `select`, `filters`,
   `ordering`, `pagination`, `representations`, `mutations`, `rpc`, `auth`,
   `errors`, `headers`, `content_negotiation`, `openapi`, `config`,
   `observability`, `domain_representations`). These describe the grammar,
   defaults, and rules of an area in prose/structured form, each claim citing a
   PostgREST source line. They are the human-readable rationale. All 17 declare
   the v16.0 pin, but the key spelling is not uniform on disk: 10 use
   `version: v16.0`, 5 use `version: PostgREST v16.0` (`errors`, `filters`,
   `observability`, `operators`, `ordering`), `pagination.yaml` uses
   `postgrest_version: v16.0`, and `url_grammar.md` states it in prose
   ("Version pinned: **PostgREST v16.0**"). Do not grep for a single spelling.

   > **Counted on disk this pass: neither the presence nor the length of a gap
   > list means what it looks like.** **Three** of the 17 models carry no `gaps:`
   > key anywhere: `errors.yaml` (which records coverage under `coverage:`, its
   > open items inline, and a `harness_gate:` key naming the Bier-side wiring
   > three of its cases need) and `content_negotiation.yaml` and
   > `operators.yaml`, which record **no gap list at all, under any
   > key**. `url_grammar.md` uses a `## Gaps` markdown section rather than a YAML
   > key. The remaining **thirteen** `.yaml` models carry between **5** and **16**
   > entries:
   > `config.yaml` and `observability.yaml` **16** each, `auth.yaml` **15**,
   > `openapi.yaml` / `filters.yaml` **14** each,
   > `mutations.yaml` / `pagination.yaml` / `select.yaml` **11** each,
   > **`domain_representations.yaml` 10**,
   > `headers.yaml` / `rpc.yaml` **7** each,
   > `ordering.yaml` **6**, **`representations.yaml`** **5**. Read the
   > model; do not assume the shape.
   >
   > **`domain_representations.yaml` doubled (5 → 10) in the pass that closed the
   > area, and its composition is the argument for writing these lists at all.**
   > Only ONE of the five new entries reports missing coverage. The others are:
   > one marked **RESOLVED and retained as a record** — `mutation_isolation`, a
   > claim that the area's whole write half *could not be modelled*, which was
   > **false** and had survived a full prior re-sync; one **cross-reference**
   > arguing that an upstream block sitting inside the area's `describe` belongs
   > to *ordering* instead, with a corrected audit naming all **four** upstream
   > data-representation sites; one **fixture-divergence hand-off** carrying the
   > exact DDL a future fold needs and the blast radius it checked; and one
   > **`loader_exposure:`** entry recording that the area's view mirror changes
   > DEFAULT resolution, which is why case 1822 carries `schema: test`.
   > **Three of the ten exist to argue a case should NOT be written** — the shape
   > `representations.yaml` introduced, and the only shape that keeps a gap list
   > from decaying into a backlog nobody reads.
   >
   > **`representations.yaml` is new to this list — it went from no gap key under
   > any name to five entries — and one of the five has no precedent in the tree.**
   > Its entries are sorted by *kind* rather than by topic: one live structural gap
   > (the `is.null` key-column `Location`, unreachable on a base table because
   > `PRIMARY KEY` implies `NOT NULL`), **two entries whose whole purpose is to
   > argue that a case should NOT be written** (the `with_multiple_pks` /
   > `compound_pk_view` de-duplication against case 1309, and the uncased
   > `count=exact` Content-Range halves), one `operator_action:` entry about the
   > inert `preconditions:` key, and one reading **`needed_assertion: nothing`** —
   > an explicit record that every behavior cased this pass was expressible with
   > the existing `case.schema.json` keys. **Copy that last one.** It pre-empts a
   > later pass re-deriving the question, and it is the only way a reader can tell
   > "the harness was sufficient" from "nobody checked".
   >
   > **A long list is not coverage, and `rpc.yaml` is the proof.** Its seven
   > entries are unusually rigorous — two argue at length against *approximating*
   > a behavior rather than omitting it — and its audit still returned **five**
   > findings, none of which any entry anticipated. Length measures how carefully
   > an author declined the gaps they *saw*.
   >
   > **`mutations.yaml` is the counter-example, and the two together bracket the
   > useful range.** Its list nearly doubled (6 → **11**) *because* of its audit,
   > and the new entries are the most operationally specific in the tree: each
   > names the missing relation, quotes the upstream it-block it blocks, and ends
   > with a `loader_exposure:` clause spelling out what the loader would have to
   > build. One entry decomposes a single upstream feature **leg by leg** —
   > composite-pk UPSERT is argued as three legs, one derivable (cased as
   > **11414**), two not, with the reason per leg: `car_models` *does* exist but
   > seeds **zero** rows, so an ignore-duplicates assertion that turns on a row
   > being *omitted* has nothing to conflict against, and a PUT-update leg that
   > first GETs a seeded row degenerates into the insert leg. Length still measures
   > nothing; **specificity** is the signal.
   >
   > **Silence is now purely a CHOICE, and the choice is being made
   > inconsistently.** `operators.yaml` was audited (✅ *pass*, **0 citation
   > defects**) and still carries no gap list under any key; its two open findings
   > and its five-column-type residual live only in `COVERAGE.md`.
   > `representations.yaml` was audited to the same verdict and **wrote its first
   > gap list**, so its residual is discoverable from the model it belongs to. The
   > evidence favours writing it — `COVERAGE.md` is 3 000 lines and the model is
   > the file a future author actually opens — and `COVERAGE.md` → follow-up 19
   > recommends resolving to "an audited area writes its gaps into its model" and
   > backfilling `operators.yaml`.
   >
   > **`content_negotiation.yaml` has now been audited too — ⚠️ *revise*, SEVEN
   > findings — and it STAYED silent, which settles two things at once.** First,
   > the category "silent **and** un-audited" is now **empty**: the one remaining
   > un-audited model (`domain_representations`) carries a gap list
   > (5 entries), so silence no longer hides an unexamined area anywhere in
   > the tree. Second, it makes `operators` the *pattern* rather than the
   > exception — **two audited areas, seven findings between them, and neither
   > wrote a single gap entry**. Backfilling both is now the concrete form of
   > follow-up 19.
   >
   > **The openapi pass is the strongest evidence for follow-up 19 so far, and
   > also the sharpest illustration of its limit.** It took its own model from
   > **6** gap entries to **14** *before* the audit ran — four RESOLVED-and-retained
   > for provenance, two `harness_gate:` entries naming the exact
   > `@variant_case_ids` edit a Bier maintainer must make, one `operator_action:`
   > on the inert `preconditions:` key, one `needed_assertion: nothing` — and it
   > wrote the tree's **second** `fixture_notes:` key (five entries). **And the
   > audit still found two behaviors with neither a case nor an entry**: the
   > `/rpc/*` per-operation `produces` / `responses.200` pair
   > (`OpenAPI.hs#L357-358`) and the shared `$.parameters.on_conflict` definition
   > (`#L239-245`), both emitted by every document the server can produce.
   > Confirmed on disk during synthesis: `on_conflict` appears in four case files,
   > **none of them in the openapi band**, and nowhere in `openapi.yaml`. A gap
   > list records the gaps its author *saw* — which is the same lesson `rpc.yaml`'s
   > seven entries taught, now with the opposite starting condition.
   >
   > **What `content_negotiation.yaml` wrote instead is worth more than the gap
   > list it skipped.** It added a top-level **`fixture_notes:`** key — three
   > entries, each naming an object (`test.unnamed_bytea_param`,
   > `public."application/octet-stream"`, `test.add_them`), the exact property its
   > cases depend on, and what silently breaks if that property changes ("giving
   > `add_them` a mime-named domain return would turn case 1623's 406 into a
   > 200"). No other model in the tree records fixture dependencies at all, and
   > this area is precisely where that gap bit: its own fixture defect made case
   > 1622 unreachable while every mechanical check stayed green. **Copy the key;
   > it is the only artifact in the tree that would have caught it.**

2. **Conformance cases** — 762 YAML files under `conformance/cases/`. Each is one
   concrete scenario: a request and the exact response (status, headers, body)
   PostgREST produces. These are the machine-checkable contract.

## Anatomy of a conformance case

Each case validates against [`case.schema.json`](case.schema.json):

```yaml
id: 1200                       # globally-unique; each area owns an id band
feature: ordering/direction/asc  # slash-delimited <area>/<sub-feature>/...
request:
  method: GET                  # HTTP shape: method + path
  path: /items?id=lte.2&order=id.asc
  headers: { Accept: application/json }
schema: ordering               # fixture-set LABEL (see "Fixtures" below)
preconditions: []              # optional SQL, declarative only — see the note
config: {}                     # optional PostgREST config the case requires
expect:
  status: 200
  headers:
    Content-Range: "0-1/*"
  body_exact: [ ... ]          # body_exact | body_jsonpath | body_contains | body_raw | body_json
notes: "..."                   # rationale, references the upstream it-block
source: https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/...#L<n>
```

The schema's `required` list is six keys — `id`, `feature`, `request`, `schema`,
`expect`, `source` — but in practice `notes` is universal too: all seven are
present on all **762** cases, verified mechanically this pass by intersecting key
sets rather than by trusting the schema. The complete key vocabulary on disk is
exactly those seven plus `preconditions` and `config`; nothing else appears.
`preconditions` is present on **761** (case **1330** is still the only omission);
`config` is present on **116** (four of those — 1705, 1719, 1727, 1743 — are the
empty `config: {}`). **The config count has not moved for six passes**: none of
the operators re-sync's 37 new cases, none of the rpc re-sync's 3, none of the
mutations re-sync's 17, none of the representations re-sync's 8, none of the
content_negotiation re-sync's 6, none of the openapi re-sync's 6 and none of the
domain_representations re-sync's 16 declares a
`config:` block, because none of those areas is
config-gated — a useful contrast with `select`, whose aggregate cases all need
`db-aggregates-enabled`. It is a pure dilution: the share of cases
carrying a `config:` block has fallen 16.3 % → 16.0 % → 15.8 % → **15.2 %**
without a single
block being added or removed. The **42** cases with a *non-empty*
`preconditions:` list break down mutations **25**, content_negotiation **11**,
pagination **4**, url_grammar **1**, representations **1** — openapi's two were
**removed** by its re-sync (both were inert *and* wrong), the only decrease this
key has recorded. Five consecutive re-syncs have now given every new case
`preconditions: []`,
establishing a convention nobody has written down (`COVERAGE.md` → follow-up 25).

Two request shapes are supported:

- **HTTP** (the common case, **724** cases): `request.method` + `request.path`,
  with optional `request.headers` / `request.body` / `request.body_raw` /
  `request.body_json`. The **auth** area may add `request.jwt` to have the runner
  mint and send a signed token (32 cases do; case 11809 instead spells out a
  literal `Authorization` header, because it needs a token signed with a secret
  the harness does not know).
- **CLI** (config startup behavior, 38 cases — all of them in `config`,
  ids **1705–1741 plus 1744**; the band is *not* contiguous, because 1742/1743
  are HTTP CORS cases sitting inside it): `request.kind: cli` with
  `request.flag: "--dump-config"`, asserting on `expect.exit_code`,
  `expect.dump_contains`, `expect.dump_reparse_stable`, and
  `expect.stderr_contains`.

Response assertions include `status`/`status_text`/`exit_code`, exact or pattern
header matches (`headers`, `headers_match`, `headers_present`, `headers_absent`,
`headers_absent_in_value`, `headers_no_blank`), and body assertions
(`body_exact`, `body_jsonpath`, `body_contains`, `body_raw`, `body_json`). See
the schema for the authoritative field list and descriptions.

> **`preconditions:` are declarative documentation only.** The frozen harness
> parses the field but never executes it; nothing in a case may depend on a
> precondition having run. `spec/pagination.yaml` records the sharpest instance:
> cases 1272/1274/1275 carry `preconditions: ["ANALYZE …"]` for planner-estimate
> expectations and pass only because `mix bier.fixtures.load` happens to run a
> database-wide `ANALYZE`.

> **One request shape is entirely untested: a `HEAD` that errors.** Thirteen
> cases use `HEAD` (1020, 1272, 1274, 1275, 1277, 1284, 1425, 1681, 1756, 1760,
> 1761, 1762, 1771) and **every one expects a 2xx** — re-derived mechanically at
> the 762-case state. The last **nine** re-syncs added **95** cases between them
> without adding a single HEAD of any kind, erroring or not, so the blind spot's
> denominator keeps growing while its numerator is frozen at 13. The
> domain_representations pass is the ninth and the first with a structural
> excuse: fourteen of its sixteen new cases are mutations, and a HEAD on a
> mutation is not a shape upstream asserts anywhere. (Its one read-shaped
> opportunity, case **1821**'s 404, is an *error* path — exactly the untested
> combination — and was written as a `GET`.)
> `COVERAGE.md` → *Known gaps → errors* costs the fix at one case.
>
> **The representations pass is now the sharpest illustration, displacing
> mutations.** SIX of its eight new cases assert a response whose entire subject
> is the **header set**, and every one of them uses `headers_absent` — 1315, 1316
> and 1317 on `Location` being absent, 1325 and 1326 on `Preference-Applied` being
> absent. That is precisely the assertion vocabulary a HEAD case uses, applied six
> times in one pass, in an area whose model is *about response shape*. The area
> still added none.
>
> **The mutations pass, retained for context.** Its 17 new cases include three
> whose whole subject is a response with **no body** — 11400 (`PATCH` → 204 with
> `Content-Range: 0-1/*` and both `Content-Type` and `Content-Length` absent) and
> 11402 (`POST` → 201 with `Content-Length: 0`). Method coverage
> across the whole tree, re-derived at **762**: GET **511**, POST **114**, CLI
> **38**, PATCH **35**, DELETE **21**, PUT **18**, HEAD **13**, OPTIONS **12**
> (sums to 762). This pass moved three of those: **+8 PATCH** (1828–1835),
> **+7 POST** and **+1 GET** — **the largest single-pass PATCH growth the tree
> has recorded**, and the reason the write half of `domain_representations` is
> the area's largest sub-feature. (An earlier revision recorded PATCH as **26**
> when it was **27** — a counting slip in this document, not a change in the
> tree.)

## Fixtures

The conformance database is built by `mix bier.fixtures.load` from
`conformance/fixtures.sql` (the authoritative artifact) plus the human-owned
`conformance/fixtures_local.sql`, followed by area-schema mirroring. A case's
`schema:` field is a **fixture-set label, not a filename**: the harness sends
any label other than `null`/`public`/`test` as an `Accept-Profile: <label>`
request header, so the label must name a schema the conformance server exposes
*or* resolve through one of the server's aliases/profile lists (`unicode` →
`تست`) *or* through the implementation-side allowlist (`multi` and `headers`;
see below). The harness sets the header with `Map.put_new`, so a case that spells
out its own `Accept-Profile` wins over the label.

> **Counted on disk this pass, unchanged.** **Fifteen** cases spell out a
> profile header of their own: **1009–1014, 1017, 1018, 1023, 1024** (ten of the
> fourteen `multi` cases) and **1558, 1559, 1560, 1574, 1583** (five `headers`
> cases). But only an explicit **`Accept-Profile`** suppresses the injection —
> `Content-Profile` does not — so of the fifteen, **twelve** actually suppress it
> and **three** (1011, 1012, 1559) do not. The consequence is that **six** `multi`
> cases receive `Accept-Profile: multi`: **1005–1008** (which set no profile
> header at all) and **1011**/**1012** (which set only `Content-Profile`).
>
> **And `multi` is not resolved by the harness at all.** It is neither a schema
> in `bier_test` nor a `db_schema_aliases` key; it resolves only because
> *implementation* code carries a hard-coded allowlist of conformance labels
> (`@profile_aliases ~w(headers multi)`,
> `lib/bier/plugs/action_controller.ex:479`) — re-verified on disk this pass.
> Three of the six (**1005**, **1008**, **1011**) expect a 2xx and therefore
> depend on that allowlist. See `COVERAGE.md` → *Open verification findings*.
> Note the machine check does **not** flag them, because its label-resolution
> step maps `multi` to the `v1`/`v2` pair itself; that is a property of the
> checking script, not a fix to the tree.

The fixture set also carries one **renamed** relation worth knowing about, because
four cases now point at a path upstream does not use: upstream's `menagerie` is
the pagination fixture's single-column *empty* table, but `openapi.sql`
contributes a 7-column type-mapping table of the same name. The consolidated
fixture keeps openapi's as `test.menagerie` and renames the empty one to
`test.menagerie_empty`; the pagination re-sync retargeted cases **1258, 1264,
1266 and 1268** onto `/menagerie_empty`, since emptiness is the whole point of
those four assertions.

> **The mutations pass is the first to use the *surviving* `menagerie`, which
> makes the rename load-bearing in both directions.** Case **11402** POSTs an
> `application/x-www-form-urlencoded` body with seven fields
> (`integer`, `double`, `varchar`, `boolean`, `date`, `money`, `enum`) to
> `/menagerie` — the openapi type-mapping table, which is exactly the relation
> upstream's `InsertSpec.hs#L171` targets. So the consolidated fixture now has one
> case set depending on `menagerie` being the 7-column table and another set
> depending on `menagerie_empty` being the empty one. Neither name is free to
> move.

Ownership rules for everything under `conformance/fixtures/` — who may write
which file, and why `<area>.delta.sql` is the only write channel — are in
[`conformance/fixtures/README.md`](conformance/fixtures/README.md). There are
**17** per-area fragments and **8** `*.delta.sql` write channels; all eight are
**comment-only**, re-verified mechanically this pass (stripping comment and blank
lines leaves zero lines in every one). Each holds a single
`-- Folded into ../fixtures.sql on <date> (…); empty until the next delta.`
provenance line and no DDL, i.e. empty as a write channel. **Three** carry the
2026-08-08 date (`headers`, `ordering`, `rpc`); **five** carry 2026-08-09
(`content_negotiation`, `url_grammar`, `errors`, `operators`, and — new this
pass — `domain_representations`). **There is still
no `mutations.delta.sql` and no `representations.delta.sql`.**

> **`domain_representations.delta.sql` is the eighth channel and the first to be
> opened, used and emptied inside a single pass.** Every earlier channel was
> opened by one pass and folded by a later one; this one carried
> `test.evil_friends_with_column_default`
> (`id public.devil_int DEFAULT 420, name text`) into `fixtures.sql` section 4
> and returned to its provenance line before synthesis. No seeds, no GRANT, no
> name collision. Verified in the catalog rather than inferred from a clean load:
> the relation resolves, `id` carries column default **420** and `name` none, and
> it holds **0** rows.
>
> **The object exists to make one precedence rule observable, and it gives
> different answers as a table and as a view.** Under `Prefer: missing=default`
> the COLUMN default (420) beats the DOMAIN default (666) on the base table —
> which is case **1822**, and why that case carries `schema: test`. Through the
> loader's auto-updatable area mirror the same DDL answers **666**, because the
> view supplies the domain default as an explicit value first. Both were checked
> on a live database. **A fixture whose behavior depends on whether it is reached
> as a table or a view is exactly the class of property no mechanical check in
> this tree inspects.**

> **`content_negotiation.delta.sql` is the first channel folded TWICE, and its
> second fold is the first in the tree to CHANGE an existing object rather than
> add one.** Every prior fold appended: a table, a domain, a routine, a computed
> field. This one re-declared `test.unnamed_bytea_param(bytea)` in place —
> `RETURNS bytea` → `RETURNS public."application/octet-stream"` — and added the
> `public."application/octet-stream"` domain it now returns, because the return
> type is the only thing that registers an octet-stream handler
> (`SchemaCache.hs#L1016`). Under the old transcription case **1622** was
> unreachable: it could only have answered 406/PGRST107.
>
> **Read the fold note in `fixtures.sql` before reading this as a fix.** It says
> so itself: 1622 was *already* passing, because `lib/bier/rpc.ex:288` offers
> octet-stream for any scalar RPC result regardless of return type — which is the
> over-permissive behavior the **new** case 1623 exists to catch (1623 currently
> fails with `42846 cannot cast type integer to bytea`, not the expected
> 406/PGRST107). The fold is upstream-fidelity groundwork that keeps 1622
> reachable once `lib/` narrows handler discovery to the return-type domain;
> under the old fixture those two cases could not both be green. The fold
> deliberately adds **no** aggregate over the new domain and **no** GRANT, which
> is what keeps 1623 (scalar) and 1624 (`SETOF`, excluded by the discovery
> query's `NOT proretset`) at 406. An A/B run of the whole suite against the
> pre-fold file reported an **identical failing-case set** — same 96 ids, zero
> regressions, zero flips.

> **The mutations pass exposed a fixture property that turns out NOT to be
> unique to it, and the correction matters before writing another write-flavored
> case in ANY area.** The
> `mutations` schema is a **view mirror** of `test`, except for ten relations the
> loader replaces with independent real tables — `items`, `articles`,
> `complex_items`, `tiobe_pls`, `simple_pk`, `no_pk`, `single_unique`,
> `compound_unique`, `safe_update_items`, `safe_delete_items`
> (`isolate_mutations/1`, `lib/mix/tasks/bier.fixtures.load.ex:541-544`, a
> hard-coded list). **Ten** of the pass's 17 new cases target relations
> **outside** that list — `menagerie` (11402), `json_table` (11403), `car_models`
> (11408, 11409, 11414), `only_pk` (11410, 11411), `tasks`/`projects` (11412),
> `students`/`students_info` (11413) and `users` (11415) — so **nine** of them
> write through auto-updatable views straight onto the shared `test.*` tables
> (11409 expects a 405 and never reaches the database). They are safe
> only because the conformance server runs with `db_tx_end: :rollback`
> (`test/support/conformance_server.ex:194`), which rolls every request
> transaction back. `mutations.yaml`'s own gaps record this. **The consequence
> for a future author**: a new mutations case against an un-isolated relation
> inherits that dependency silently, and any change to `db-tx-end` on the shared
> instance would corrupt the read-only areas rather than fail the case.
>
> **`representations` has the same structure with a different list, which is why
> the previous revision's "the other areas never touch this" was wrong.**
> `isolate_representations/1` (`lib/mix/tasks/bier.fixtures.load.ex:459-460`)
> replaces exactly **five** relations with independent real tables — `items`,
> `projects`, `clients`, `complex_items`, `auto_incrementing_pk` — and
> **`no_pk` is not among them**. So the representations re-sync's cases **1316**
> and **1317** (both `POST /no_pk`) write through `representations.no_pk`, a plain
> view mirror, straight onto `test.no_pk`, contained only by the same
> `db_tx_end: :rollback`. Its other four writes (1315, 1318, 1319, 1327) target
> `complex_items`, which *is* isolated. **Two hard-coded lists, two areas, the
> same silent dependency, and neither area's cases declare it** — see
> `COVERAGE.md` → follow-up 27. Check the relevant `isolate_*` list before
> choosing a target relation for a write case.

> **The rpc re-sync added no channel and no object, and that was the right
> call.** `fixtures.sql` does not appear in `git status`; `rpc.delta.sql` is
> unchanged. All three new cases run against routines the consolidated fixture
> already had (`rpc.ret_void`, `rpc.variadic_param`) or, for case 1443, against
> the deliberate *absence* of `test.sayhell` beside the present `test.sayhello`.
> Its audit's three fixture-blocked findings were left **open and recorded**
> rather than half-closed with substitutes — and their blocker is
> **ownership**, not absence: the routines belong in the human-owned
> `fixtures/rpc.sql`, which no workflow agent may edit, so a spec pass can only
> reach schema `test` through `rpc.delta.sql`. Decide that once
> (`COVERAGE.md` → follow-up 22) before authoring any of them.

> **The operators re-sync is the only one so far to add fixture objects through
> a delta.** `operators.delta.sql` records the fold of
> `test.items_with_different_col_types` (one column per base type, with
> upstream's single `int_data = 1` seed row), `test.tsearch_to_tsvector` (the
> same five documents as the pre-existing and **distinct** `test.tsearch`, but
> stored unconverted as text/jsonb/domain so the automatic `to_tsvector()`
> coercion is what does the work), the two domains `test.tsvector_not_null` and
> `test.tsvector_not_empty` (the second defined over the first, which is what
> makes a *recursive* tsvector domain distinguishable from a plain one), and the
> computed field `test.text_search_vector(test.tsearch_to_tsvector)`. Nothing was
> renamed — no folded name collided — and no `GRANT` was needed, because the
> loader mirrors `test` relations into the area schemas as views.

> **One existing fragment *was* edited (once, by an earlier re-sync), and the
> exception is narrow enough to state precisely.** The observability re-sync
> modified `conformance/fixtures/observability.sql` — **comment-only**: it
> re-pinned the header's provenance URLs from `blob/v14.12` to `raw/v16.0` (all
> seven anchored line numbers verified unchanged) and added two missing
> provenance lines for objects the file already created. No DDL, no seed row, no
> object added, removed or altered. That is the only kind of edit to an existing
> fragment a re-sync has made; anything touching *objects* still goes through a
> `<area>.delta.sql`.

See [`conformance/INDEX.md`](conformance/INDEX.md) for the full
area ↔ id-band ↔ fixture ↔ label map.

## How this drives the Tester

This `spec/` tree is the output of the spec-research phase. The **Tester**
consumes it: `test/conformance/conformance_test.exs` generates one ExUnit test
per case, `test/support/conformance_server.ex` boots the shared instances (plus
per-case config variants), and `Bier.HttpCase`/`Bier.CliCase` replay the request
and assert the response matches `expect`. The Tester owns `case.schema.json` and
the CI lint gate. The area models guide implementation; the cases are the
pass/fail contract.

> `CLAUDE.md` still says "532 cases". That is stale relative to this tree, which
> holds **762**.

Everything under `spec/` and `test/` is **frozen ground truth** for
implementation work: fix `lib/` to match the cases, never edit the cases to
match `lib/`. The two scoped exceptions (re-syncing to a new PostgREST pin via
the `bier-spec` / `bier-spec-audit` workflows, and human-reviewed edits to
`fixtures_local.sql`) are described in `CLAUDE.md`.

## Validating cases locally

```sh
pip install pyyaml jsonschema
python3 - <<'PY'
import glob, yaml, json, jsonschema
schema = json.load(open("spec/case.schema.json"))
v = jsonschema.Draft202012Validator(schema)
bad = 0
for f in glob.glob("spec/conformance/cases/*.yaml"):
    for e in v.iter_errors(yaml.safe_load(open(f))):
        bad += 1; print(f, e.message)
print("OK" if not bad else f"{bad} errors")
PY
```

All **762** cases currently parse and validate, with **no duplicate ids** (762
files, 762 distinct ids, and every `NNNN_` filename prefix equals the in-file
`id:` — re-derived across all **four** 5-digit bands: operators' 102xx,
mutations' 114xx, auth's 118xx and content_negotiation's 124xx).
Toolchain: PyYAML +
jsonschema `Draft202012Validator`. Remember the caveat above: a clean
run proves shape, not pin — the `source` pattern accepts any tag. The validator
was proved live, not vacuous, by negative controls on a mutated copy of a
pristine case (unknown key, dropped required key, wrong `id` type, and a
malformed `source` were all caught); the one control it **fails** is the
stale-pin rewrite, which is why the URL sweep above exists. Those controls were
run in an earlier pass and are not repeated every time — the failure they record
is a property of the schema's `source` pattern, which has not changed.

## Review status

Citations are **self-reported**: every case carries a pinned `source:` URL with
a line anchor. The v16.0 re-sync's adversarial review — re-fetching the cited
line and confirming it still asserts what the case claims — is summarized
per area in [`COVERAGE.md`](COVERAGE.md), together with the open gaps and the
machine-verification results for this pass.

**All seventeen** areas now carry a recorded v16.0 adversarial verdict, and
**every one of the seventeen reports 0 citation defects** — no verdict has ever
turned on a
mis-cited line. **Thirteen** are ⚠️ *revise*: **auth**, **headers**, **config**,
**select**, **filters**, **ordering**, **url_grammar**, **pagination**,
**observability**, **rpc**, **mutations**, **content_negotiation** and
**openapi**, every
finding a missing-coverage or mis-modelled-rule gap itemized in `COVERAGE.md` →
*Known gaps*. **Four** are
✅ *pass*: **errors**, **operators**, **representations** and now
**domain_representations**, whose findings
are all explicitly MINOR / non-blocking or were closed in-pass. **There is no
un-audited area left**; `COVERAGE.md` → follow-up 1 is CLOSED.

> **The `domain_representations` verdict is the one this pass adds, and it
> completes the audit of the tree.** ✅ *pass*, **0 citation defects**, 21 →
> **37** cases (sixteen new, three rewritten, **one fixture object authored AND
> folded**), and **one** non-blocking finding — the smallest count in the tree.
> That finding is the docs' `json`→domain **no-cast fallback** note
> (`domain_representations.rst#L159`), for which **PostgREST v16.0 ships no test
> at all**, so there is no it-block to cite; case **1814** exercises the same
> code path in substance (a cast-less `devil_int` value serialized by its base
> type), differing only in that the value is a default rather than
> client-supplied. The read-side twin of that note (`#L109`) **is** covered, by
> case 1809.
>
> **The pass's own largest output came from retiring a gap that claimed the work
> was impossible**, which is a tenth species for the list below. The recorded
> entry `mutation_isolation` held that the area's whole write half could not be
> modelled because the shared conformance instance cannot isolate mutations. It
> can — `db_tx_end: :rollback` plus `Bier.Mutation.finish_tx/3`, the same
> isolation upstream gets from `configDbTxRollbackAll = True`. **A claim of
> impossibility, unchallenged through a full re-sync, was worth fourteen cases.**
> When a gap entry says a case *cannot* be written, check the harness before
> believing it.
>
> **And its one near-miss is the most instructive thing on disk about labels.**
> Case **1822** had to carry `schema: test` rather than the area's own mirror,
> because an auto-updatable view resolves a missing INSERT column against the
> *view's* domain default (666) before the base table's column default (420) can
> fire. Both answers are "correct"; only one is upstream's. **No mechanical check
> in this tree can tell them apart** — the label resolves either way, the
> relation exists either way, and only inserting both ways on a live database
> distinguishes them. Three consecutive passes have now met a fixture *property*
> no check reads (a routine's return type, a non-existent schema name, and this);
> this is the first one caught **before** shipping.

> **The openapi verdict is the one this pass adds, and its two live findings are
> the cheapest open items anywhere in the tree.** ⚠️ *revise*, **0 citation
> defects**, 33 → **39** cases (six new, **33 rewritten**, one authored then
> **withdrawn**, **no fixture object**). Both uncovered behaviors are emitted by
> **every** document the server can produce, and neither had a case *or* a gap
> entry before the audit: the per-operation `produces` / `responses.200` pair on
> every `/rpc/*` path item (`OpenAPI.hs#L357-358`) and the shared
> `$.parameters.on_conflict` parameter definition (`#L239-245`). **Zero coverage
> plus zero disclosure is a worse state than a long gap list**, and it is exactly
> the state a "the area was already re-synced" reading would have left in place.
>
> **The pass's own largest correction was not a citation but a `schema:` label**,
> and it is a ninth species for the list below. Every one of the 33 rewritten
> cases changed its label; **31** of them carried `schema: openapi`, naming a
> schema that **does not exist** in `bier_test`. The
> harness turns any label other than `nil`/`public`/`test` into an
> `Accept-Profile:` header, so those cases shipped `Accept-Profile: openapi` and
> would describe an **empty document** against a faithful implementation. They
> passed only because Bier does not resolve the profile for the root path today —
> i.e. for a reason the spec must not depend on. Those 31 and the one
> `openapi_variadic` case now carry `schema: test` (the label upstream's own
> `baseCfg` reproduces), and the 33rd — case **1654** — moved from the equally
> non-existent `openapi_no_schema_comment` to `openapi_no_comment`, a schema that
> **does** exist (`fixtures.sql#L247`). **A green case can be green because of a
> bug in the thing it is testing.**
>
> One arithmetic note for anyone reconciling this against `openapi.yaml`: its
> resolved gap entry says "all **38** cases that carried `schema: openapi`". 38 is
> the number of openapi-band cases that carry `schema: test` **now** (38 + the one
> `openapi_no_comment` = 39); the number that carried `schema: openapi` **before**
> was 31. The entry's substance is right and its count is a conflation of the two
> sides of the change.

> **The content_negotiation verdict is the one to read if you only read one, and
> its lesson is not about citations.** It returned **seven** findings and **0
> citation defects** — the second-largest finding count in the tree, after rpc's
> five was surpassed — against the area whose model had been silent from the
> start. Three of the seven are worth naming here because they are *classes*:
>
> - **A documented config gate with no case, declared in a key the harness never
>   executes.** The model states twice that plan media types resolve only under
>   `db-plan-enabled = true` (`Plan/Negotiate.hs#L74`). Five cases
>   (**1625–1628**, **1643**) record that requirement in a `preconditions:`
>   string — parsed, never run — and **nothing pins the 406** the default
>   produces, which upstream asserts at `PlanSpec.hs#L544`. A declaration the
>   harness ignores is not a test, and this is the tree's clearest instance.
> - **A defective FIXTURE that made a case's assertion unreachable while every
>   mechanical check stayed green.** See the eighth-species note above.
> - **A modelled mechanism that was wrong at its root and survived because the
>   fixtures made it *look* right.** The model described a custom media handler
>   as an aggregate whose **stype** is the mime-named domain. Discovery keys on
>   the **return type** (`proc.prorettype`, `SchemaCache.hs#L1062-L1071`), plus a
>   second branch for plain non-set-returning functions (`#L1080-L1086`). stype
>   coincides with the return type exactly when the aggregate has no finalfunc —
>   true of every fixture in this tree, which is why no case could distinguish
>   them. **An implementation built from the old rule registers a subtly
>   different handler set**, and upstream's own docs phrase it loosely enough
>   ("the return type of their transition or final functions") to mislead.
>
> Read together with the rpc verdict, the pattern is that **the areas this
> workflow has already re-synced are not the areas it has verified**, and the two
> largest finding counts both came from audits of areas that looked finished.

> **The representations verdict is the argument against deprioritizing an area
> you expect to pass.** It came back ✅ *pass* with **0 citation defects** — and
> still produced **eight** new cases (1315–1319, 1325–1327), a **first** gap list
> where the model had none, a **narrowed citation** (`InsertSpec.hs#L745` →
> `#L157` + `#L99`, because the old anchor's enclosing `describe` scoped it to
> views) and a **corrected gap entry** (the claim that `compound_pk_view` adds a
> view-specific angle case 1309 misses is false — `car_models` is not in
> `isolate_representations`' real-table list, so 1309 already runs against a view
> mirror). It also **discharged a concrete cross-area exposure**: case **1332** in
> this band is the tree's only PUT + `return=minimal` assertion, and the mutations
> pass had deleted its own clone (11406) on the strength of it while the band was
> still unaudited. A *pass* verdict is not a null result.
>
> **It also broke the tree's implementation-anchored plateau, deliberately.**
> Seven of its eight new cases anchor at `src/library/PostgREST/…` rather than an
> upstream `it`-block, taking the tree **46 → 53** (6.3 % → **7.2 %**) after three
> flat passes. That is not a defect — upstream asserts none of the seven rules
> black-box, and each case says so in its `notes:` — but it is the largest
> single-pass movement that metric has had, and it suggests the same will happen
> when `content_negotiation` is audited, since both areas' subject is *response
> shape* rather than *query semantics*.

> **The mutations verdict is the first whose findings were substantially *closed
> inside the same pass*, and that is worth reading carefully.** Its audit drove
> four extra cases (**11412–11415**, the resource-embedding-on-mutations set) and
> five extra gap entries, so the on-disk residue is a *shorter* list of open work
> than any other *revise* area — while the verdict itself stays *revise* because
> the remaining findings are real. **Do not read a closed finding as a covered
> behavior**: the four cases cover the embedding flavors whose relations the
> consolidated fixture happens to have, and the gap entry that records them
> immediately enumerates the ones it does not (`web_content`'s four
> self-reference flavors, `artists`' order and batch-upsert flavors, and the
> DELETE one-to-one reverse direction). The pass also **authored and then dropped
> a case** — 11406, a PUT `return=minimal` clone — on discovering that case
> **1332** in the representations band already mirrored the same it-block with
> strictly stronger assertions. That deletion is recorded in `mutations.yaml`'s
> gaps rather than left silent, which is the behavior to copy.

> **The rpc verdict is the strongest argument yet for finishing the remaining
> three, because it is the first audit to hit an area this same workflow had just
> re-synced.** It returned **five** findings — the most any single area audit has
> produced — including **two whole H2 sections of the *Functions as RPC* docs
> page** with no case, no model entry and no gap note: *Untyped functions*
> (routines returning `record` / `SETOF record`) and *Functions with array
> parameters* (a **non**-variadic array-typed parameter). Also missing: the
> `text/plain` and `text/xml` flavors of the single unnamed parameter (only the
> bytea flavor is covered, and from the *content_negotiation* area), resource
> embedding through a table-valued function (exercised only incidentally, by a
> `url_grammar` case), and `?columns=` on an RPC POST. **A completed re-sync is
> not evidence of coverage; only an audit is.**

> **The operators pass is the only one to close another area's gap, and that is a
> structural note, not a scoreboard entry.** The `IN`/`NOT IN` empty-set behavior
> was raised as a **filters** gap ("no case in the whole tree issues an `in.()`
> request"). It is now covered by operators cases **10200–10205** against a folded
> `test.items_with_different_col_types`, because the *SQL rendering* of `in` —
> the `[""] -> "= ANY('{}')"` branch — was already modelled in `operators.yaml`.
> When a gap's docs page and its source-level rule live in different areas, the
> gap will be recorded by one and closed by the other; check `COVERAGE.md`'s gap
> sections against disk before assuming a listed gap is still open.

> **Five verdicts should be read as warnings about the remaining two, and each
> names a different way a model can be wrong.**
>
> The **mutations** finding is the mildest and the easiest to reproduce: an
> uncited rule. `mutations.yaml` claimed `?columns=` applies to PUT; nothing at
> v16.0 says so and the PUT docs say the opposite. The claim survived because it
> was *plausible* — `columns=` really does apply to POST and PATCH — and because
> no case exercised it either way, so there was nothing to fail. **An unexercised
> model entry is unverified by construction**, whatever its neighbours cite.
>
> The **pagination** findings were not merely "a case is missing": one modelled
> *rule* was **wrong** — the Range header was documented as *overriding*
> limit/offset, when `getRanges` **intersects** them — and the single upstream
> it-block on the subject (`RangeSpec.hs#L194`, case 1261) is the one shape where
> the two rules coincide, so no existing case could have caught it.
>
> The **observability** findings went one step further: the modelled rule that
> `OPTIONS` responses omit the `plan` and `transaction` Server-Timing metrics was
> false at **both** pins, three cases asserted it, **and `lib/` implemented it**
> (`lib/bier/plugs/observability.ex:159`). Spec and implementation agreed with
> each other and with nothing upstream, so the suite was green on an invented
> behavior. A green suite is not evidence that a model is right; it is not even
> evidence that the behavior exists.
>
> The **representations** finding is the subtlest and the hardest to mechanize: a
> citation that is real, fetchable, correctly pinned, and proves a **narrower**
> claim than the model attached to it. `InsertSpec.hs#L745` does assert that a
> POST without `return=headers-only` carries no `Location` — but under
> `describe "Inserting into VIEWs"`, against `/compound_pk_view`, so it witnesses
> the rule on a **view** and says nothing about a table. Every check in this
> document passes on that citation, and so does a line-level "does the cited line
> support the claim?" read. **Only reading the enclosing `describe` catches it.**
> Note that this one surfaced in an area that came back ✅ *pass*: the verdict
> grades the citations, not the model's reach.
>
> The **content_negotiation** finding is the one none of the four anticipated,
> because it is not about a citation at all: **the FIXTURE was wrong.**
> `test.unnamed_bytea_param` was transcribed as `RETURNS bytea` where upstream
> returns the mime-named DOMAIN, so case 1622's asserted 200 was unreachable
> against a faithful PostgREST. Pin, schema, filename, cited line and relation
> existence all checked out — and the case *passed*, because `lib/` was
> over-permissive in the matching direction. **The four warnings above all
> concern what a model claims; this one concerns what the database actually is,
> and nothing in this tree was checking that.** The same pass also found the
> modelled handler-discovery mechanism keyed on the wrong catalog column
> (`stype` rather than `proc.prorettype`), undetectable because every fixture
> here has no finalfunc and so makes the two coincide. **One area remains
> un-audited — `domain_representations` — and *type declarations* are its entire
> subject.** The openapi pass, audited since, produced no fixture defect of its
> own but wrote the tree's **second** `fixture_notes:` key (five entries) for
> exactly this class of exposure: its cases assert over volatility keywords,
> argument modes, return types, `COMMENT`s and `GRANT`s, none of which any check
> in `COVERAGE.md` inspects.

Note what "zero citation defects" does *not* mean: **57** cases anchor their
`source:` at implementation code under `src/library/PostgREST/…` rather than at
an upstream `it`-block, so their expected bodies are derived rather than
transcribed. Its history is 36 → 42 → 46 → 46 → 46 → 46 → 53 → 53 → **57**.

> **The total moved +4 this pass, and unusually the composition moved further
> than the total.** The openapi pass produced **five** motions in one area:
> **1651** moved *onto* implementation code (`RootSpec.hs#L27` →
> `Response.hs#L208`), **1662** likewise (`OpenApiSpec.hs#L117` →
> `OpenAPI.hs#L321`), three of the six new cases arrived there
> (**1684** `OpenAPI.hs#L158`, **1687** `#L367`, **1688** `#L405`) — and **1682**
> moved *off* it, to `docs/references/api/openapi.rst#L71`, the **only** place
> that prints the `db-root-spec` document the case asserts byte for byte. Net +4,
> and the openapi band alone went 3 → **7**. Two of the five (1687, 1688) exist
> *because* no upstream `it`-block reads those keys at all — the whole-document
> schema validation in `SpecHelper.hs#L115-123` is upstream's only witness — so
> the growth is a direct measure of a hole in upstream's black-box suite, not of
> sloppy anchoring.
>
> **The previous pass's total did not move, and that was a COINCIDENCE — read the
> composition, not the number.** Four separate motions cancelled exactly:
> case **1600** moved *off* implementation code (`MediaType.hs#L69` →
> `RawOutputTypesSpec.hs#L15`, because the audit found an it-block that asserts
> the request, body *and* `Content-Type` this case had only derived); the old
> case **1623** was *deleted* (it anchored at `MediaType.hs#L62`); and two
> arrived — the **re-issued 1623** (`SchemaCache.hs#L1016`, that
> `initialMediaHandlers` registers exactly four handlers and octet-stream is not
> among them) and **1648** (`MediaType.hs#L127-L129`, the module **doctest** for
> case-insensitive decoding, which is upstream ground truth of a different kind
> rather than an absence of it). −2 +2. **A flat metric across a pass that
> changed six cases is not evidence of stability**, and a moving one across a
> pass that touched thirty-nine is not evidence of drift. Read the motions.

The seven that produced the last real movement before this one are all
representations cases —
**1315**/**1317** (`Query/Statements.hs#L48`/`#L49`, the two Location
suppressions), **1318** (`ApiRequest/Preferences.hs#L100`, duplicate `return=`
resolves to the first token in *request* order), **1319** (`Plan.hs#L207`, an
unknown value is ignored unless `handling=strict`), **1325**/**1326**
(`Response.hs#L283`/`#L281`, `return=` not echoed on reads or RPC) and **1327**
(`Preferences.hs#L179`, fixed `Preference-Applied` order) — and every one pins a
rule **upstream never asserts black-box**, which each says in its `notes:`. The
implementation-anchored *share* is **7.48 %** (57/762) — **down** for the first
time, because the numerator did not move at all this pass while the denominator
grew by 16. **Every one of the sixteen new `domain_representations` cases anchors
on an upstream it-block**, not on implementation code, which is the outcome this
metric exists to encourage. (It was 7.6 % at 746 and 7.2 % at 740.) Re-derived
citation composition at the
**762**-case state: **546** cases cite `test/spec/Feature/Query` (**+16** — the
whole of this pass, and the first movement this bucket has had;
count it *excluding* `Query/Preferences`, or it reads 563),
**44** `test/spec/Feature/Auth`, **34** `test/spec/Feature/OpenApi`, **17**
`test/spec/Feature/Query/Preferences`, **14** `test/spec/Feature`,
**1** `test/spec/SpecHelper.hs` (case 1650, new this pass — the first case in the
tree to anchor at upstream's shared helper rather than at a Feature spec),
**47** the `test/io` tree, **2** the documentation (**1682**
`docs/references/api/openapi.rst#L71` joins **1279**
`docs/references/api/pagination_count.rst#L52`), and **57** implementation code.

**The pattern the previous revision drew from this metric needs qualifying.** It
predicted that `content_negotiation` — a *response-shape* area, like
observability (+4) and representations (+7) — would grow the set again. It did
not: the area added two implementation anchors and shed two, netting zero. What
actually distinguishes the growing passes is narrower than "response shape": both
were areas where upstream's black-box suite asserts *nothing at all* about the
rule being pinned. content_negotiation's audit found the opposite problem — real
upstream it-blocks (`PlanSpec.hs#L544`, `CustomMediaSpec.hs#L188/#L208/#L346/#L369`,
`RpcSpec.hs#L1168`) that simply have no case. **Missing black-box coverage and
implementation-anchored coverage are different failure modes, and this pass
separated them.**

**But "no anchor moved off implementation code" is not "no anchor moved."** The
mutations pass moved one, **within** the test suite and to a different it-block:
case **1352** went from `InsertSpec.hs#L218` (the single-object no-pk block) to
`#L268` (`context "with bulk insert"` / `it "returns 201 but no location
header"`), because the case is a *bulk* insert and had been citing the wrong
assertion for its own request shape. Its `notes:` now record both the correct
anchor and the reason the Location-absent assertion holds twice over on `no_pk`.
That was the third distinct species of anchor motion this document has recorded —
off implementation code (**1189**, **1016**, **1767**), onto it (1757/1768/1769,
when a retracted claim could only be refuted at the control flow), and
**sideways**, from one it-block to the correct one.

**The representations pass adds a fourth: NARROWING.** The model's
`InsertSpec.hs#L745` citation moved to `#L157` + `#L99` — same file, same suite,
but the old anchor sat under `describe "Inserting into VIEWs"` and so proved the
Location-absence rule only for a view; case **1309** was rewritten with it.
**Four directions now, each discovered by a different area's audit**, which is
the real point: re-anchoring is a *finding*, not hygiene, and no two audits have
found the same kind.

**The content_negotiation pass adds a fifth, and it is the inverse of narrowing:
SPLITTING one anchor into many.** Case **1622** kept its `source:`
(`RpcSpec.hs#L1184`) but its audit found that the anchored it-block asserts only
`respBody == file` — no status, no `Content-Type` — so the case had been
attributing two assertions to a line that makes neither. Rather than move the
anchor, the case now cites the rest **piece by piece in its `notes:`**: the
fixture declaration that makes octet-stream negotiable at all
(`schema.sql#L2372`), both branches of the handler-discovery query
(`SchemaCache.hs#L1062`, `#L1080-L1086`), the built-in handler map that excludes
octet-stream (`#L1016`), the sibling it-block that pins the 200
(`RpcSpec.hs#L1257`) and the charset rule (`MediaType.hs#L62`). **One `source:`
per case is a schema constraint, not an epistemic one** — when a case asserts
more than its anchor proves, the fix is more citations, not a different anchor.
Case **1600** in the same pass moved in the ordinary direction (off
`MediaType.hs#L69` onto `RawOutputTypesSpec.hs#L15`), joining 1189/1016/1767.

> **The same pass also did something no earlier pass has: it DELETED a case and
> REUSED its id.** Old **1623** (`octet-stream/no-charset`, a 200) is gone; its
> assertion was folded into 1622, and `1623` now names an unrelated **406**
> negative. Compare the mutations pass, which deleted 11406 and deliberately left
> the id vacant so the deletion stayed legible. **Two deletions, two opposite
> conventions, and no rule on disk** — `COVERAGE.md` → follow-up 26. Until it is
> settled, treat a case id quoted in any older document as a *label*, not a
> handle: check the `feature:` line before trusting it.

Separately, case **1279** is the tree's **first and only case
anchored at the documentation** rather than at either the test suite or the source
(`docs/references/api/pagination_count.rst#L52`, the open-ended `Range: 10-`
paragraph). The rest are behaviors upstream never asserts black-box, and each
says so in its `notes:`.
