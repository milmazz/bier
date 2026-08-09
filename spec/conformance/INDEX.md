# Conformance case index

Cross-reference of the **762** conformance cases under `spec/conformance/cases/`.
Pinned target: **PostgREST v16.0** (all 762 `source:` URLs, re-derived on disk
this pass by parsing each case's `source:` value and extracting its tag —
`{'v16.0': 762}`, no other value).

Each case is one YAML file `NNNN_<slug>.yaml` validated against
[`../case.schema.json`](../case.schema.json). Cases are grouped into 17 feature
areas; each area owns a non-overlapping id band and is backed by one SQL fixture
fragment in [`fixtures/`](fixtures/).

The `schema:` field inside a case is a **fixture-set label, not a filename**:
the frozen harness (`test/support/http_case.ex`) sends any label other than
`null`/`public`/`test` as an `Accept-Profile: <label>` header, so the label must
name a schema the shared conformance server exposes *or* resolve through one of
its aliases / profile lists. Several labels are not schema names on disk —
`unicode` → `تست`, `multi` → the `v1`/`v2` pair — and several are overridden by
an explicit header. See the **Label caveats** section below.

The first `/`-delimited segment of each case's `feature:` field is the
**authoritative** area assignment. The id bands below are derived from what is on
disk now; read the `feature:` prefix if a row ever looks ambiguous.

> **Non-contiguous bands.** **Five** areas do not occupy a single contiguous
> range and regenerating this file must preserve that rather than collapsing it:
>
> - **auth** uses **11800–11818** on top of its full primary band **1450–1499**
>   (all 50 primary ids are in use). `11800` sorts immediately after `1180` in a
>   *lexical* listing, so they interleave with the filters area's 1180–1199 cases
>   unless ids are sorted **numerically**.
> - **operators** uses **10200–10236** on top of its full primary band
>   **1050–1099** (all 50 primary ids are in use) — 37 contiguous ids with no
>   gaps, and **10237+ is free**. `10200` sorts immediately after `1020`
>   lexically, so these 37 interleave with the *ordering* area's 1200-block the
>   same way auth's do with filters'.
> - **mutations** (new this pass) uses **11400–11405 + 11407–11415** on top of its
>   now-full primary band **1350–1399** (all 50 primary ids are in use; 1398 and
>   1399 took the last two). **11406 is absent on purpose** — see below —
>   and **11416+ is free**. `11400` sorts immediately after `1140` lexically, so
>   these 15 interleave with the *select* area's 1140–1149 block.
> - **representations** uses **1300–1327 + 1330–1333** — **32** cases, one single
>   internal hole at **1328–1329**, which is per-sub-feature spacing before the
>   PUT block starts at 1330. **1315–1319 and 1325–1327 are all occupied**
>   (headers-only/no-PK/duplicate-token/unknown-token, then the two
>   `return=`-not-echoed cases and the fixed `Preference-Applied` order), so this
>   area's only free primary ids are 1328, 1329 and 1334–1349. An earlier
>   revision of this page described 1315–1319 and 1325–1329 as empty spacing;
>   that was stale — always re-derive the band from the `feature:` prefix.
> - **content_negotiation** uses **12400–12401** on top of its
>   now-full primary band **1600–1649** (all 50 primary ids are in use; 1647,
>   1648 and 1649 took the last three). **12402+ is free.** It is the tree's
>   **fourth** 5-digit band and the **only one that lands in an empty lexical
>   neighbourhood**: `12400` sorts between `1232` (ordering's last) and `1250`
>   (pagination's first), i.e. into the free 1233–1249 slice, so it interleaves
>   with nothing. That is luck, not design — `content_negotiation.yaml` declares
>   no overflow range, exactly as `operators.yaml` and `mutations.yaml` do not.
>
> **There are still FOUR 5-digit bands, so `ls spec/conformance/cases/` is actively
> misleading — always `ls | sort -n`.** The `feature:` prefix remains
> authoritative; an id's numeric neighbourhood never decides its area.
>
> **The domain_representations pass opened NO fifth band and left the area
> contiguous, which is the first time an area that grew by 16 cases did not have
> to make a band decision.** Its primary band had room: **1800–1820 → 1800–1836**,
> unbroken, with **1837–1849 free** before the area's slice ends. That is worth
> naming because the four 5-digit bands all came from areas whose primary band
> filled at 50 while nobody was watching the headroom — **the domain_representations
> band is 50 wide (1800–1849) and is now 74 % used**, so the next substantial pass
> here *will* face follow-up 19's question. The `computed_rels_datarep_response`
> gap already reserves **[1837..1849]** in prose for the case it would enable, which
> is the closest thing in the tree to an area declaring its own headroom.
>
> **An id was REUSED this pass, which no previous pass has done, and it is the
> single most misleading thing on disk if you read ids as stable handles.**
> `1623_octet_stream_no_charset.yaml` was **deleted** and `1623` re-issued to
> `1623_octet_stream_not_registered_scalar_rpc_406.yaml` — a different request
> (`GET /rpc/add_them` instead of `POST /rpc/unnamed_bytea_param`), a different
> sub-feature (`octet-stream/not-registered-406` instead of
> `octet-stream/no-charset`) and the opposite expectation (**406/PGRST107**
> instead of 200). The deleted case's assertion was not dropped: its
> no-charset `Content-Type` claim was **folded into case 1622**, which now
> asserts it directly alongside `body_raw` byte equality. **Contrast 11406**,
> where the mutations pass deleted a case and left the id permanently vacant so
> the deletion stayed visible. Two deletions, two opposite conventions, and
> nothing on disk says which is right — see
> [`../COVERAGE.md`](../COVERAGE.md) → follow-up 26. In the meantime: **an id
> cited in an older document may not name the case that document meant.**
>
> **The openapi pass supplies a THIRD convention, and it is the only one that
> costs nothing.** Case **1689** was authored, found red for a harness reason
> (its `config:` block is inert outside `@variant_case_ids`), and **withdrawn
> before it was ever committed** — so `1689` never appears in git history, the
> band is a clean contiguous **1650–1688**, and 1689 is simply the next free id.
> The behavior is not lost: `openapi.yaml` carries it as an entry with
> `cases: []` that spells the case out verbatim for restoration. **Three passes,
> three conventions — reuse (1623), permanent vacancy (11406), never-consumed
> (1689) — and follow-up 26 now has a third data point that arguably settles it:
> the cheapest place to withdraw a case is before it has an id on disk.**
>
> **The internal gap at 11406 is a different kind of hole from every other gap on
> this page and must not be closed up.** Representations' 1328–1329 gap is
> sub-feature spacing. **11406 marks a case that was written and then
> deleted**: it would have asserted PUT + `Prefer: return=minimal`
> (`UpsertSpec.hs#L543`), and it was dropped on discovering that representations
> case **1332** already mirrors that it-block with strictly stronger assertions
> (it also asserts the empty body). `spec/mutations.yaml`'s gaps record the
> deletion and re-aim the entry at what genuinely is uncovered — the
> **case-sensitive-identifier** flavor, upstream's quoted `/UnitTest` relation,
> which the fixture DB does not have.
>
> **The FOUR overflow bands follow four different placements and only one
> declaration, and this pass is the fourth-area event follow-up 19 was written to
> prevent.** `spec/filters.yaml` *declares* `[10600..10799]` as its area's closed
> overflow range (and has used none of it); `spec/operators.yaml` declares
> nothing — its band exists only as the ids on disk; `spec/mutations.yaml`
> likewise declares nothing and chose 11400+, which lands numerically *between*
> operators' and auth's ranges; **`spec/content_negotiation.yaml` declares
> nothing either** and chose **12400+**, the highest so far. **Four areas, one
> declaration, four ad-hoc placements.** `rpc` still holds 1400–1443 with only
> 1444–1449 free before auth starts at 1450, while its audit left **five** open
> findings that need more than six cases — so a **fifth** area will face the same
> question. See [`../COVERAGE.md`](../COVERAGE.md) → follow-up 19 before anyone
> picks a number.

## Area <-> id band <-> fixture fragment

| Area | Cases | Id band | Fixture fragment | `schema:` labels used |
|------|------:|---------|------------------|-----------------------|
| url_grammar | 36 | 1000–1035 | `fixtures/url_grammar.sql` + `fixtures/url_grammar.delta.sql` (case 1029's `test.pgrst_reserved_chars` and case 1035's `test."Server Today"`, both folded) | `test` (18), `multi` (14), `unicode` (3), `ordering` (1) |
| operators | 87 | 1050–1099, 10200–10236 | `fixtures/operators.sql` + `fixtures/operators.delta.sql` (`test.items_with_different_col_types`, `test.tsearch_to_tsvector`, the `test.tsvector_not_null`/`tsvector_not_empty` domains and the `test.text_search_vector(test.tsearch_to_tsvector)` computed field, all folded) | `operators` (87) |
| select | 50 | 1100–1149 | `fixtures/select.sql` | `test` (50) |
| filters | 50 | 1150–1199 | `fixtures/filters.sql` | `test` (50) |
| ordering | 33 | 1200–1232 | `fixtures/ordering.sql` | `ordering` (30), `test` (2), `mutations` (1) |
| pagination | 39 | 1250–1288 | `fixtures/pagination.sql` (**no delta** — the v16.0 re-sync added eleven cases and zero fixture objects) | `pagination` (39) |
| representations | 32 | 1300–1327, 1330–1333 | `fixtures/representations.sql` (**no delta**) | `representations` (31), `rpc` (1 — case 1326, the RPC half of the "`return=` echoed only for mutations" rule) |
| **mutations** | **65** | **1350–1399, 11400–11405, 11407–11415** | `fixtures/mutations.sql` (**no delta** — the v16.0 re-sync added seventeen cases and zero fixture objects) | `mutations` (65) |
| **rpc** | **44** | **1400–1443** | `fixtures/rpc.sql` + `fixtures/rpc.delta.sql` (`test."true"()`, folded — the v16.0 re-sync's three later cases 1441–1443 needed **no** new objects, and `fixtures.sql` was not modified at all) | `rpc` (40), `test` (4) |
| auth | 69 | 1450–1499 **+ 11800–11818** | `fixtures/auth.sql` | `auth` (69) |
| errors | 27 | 1500–1526 | `fixtures/errors.sql` + `fixtures/errors.delta.sql` (cases 1523/1524's `test.infinite_inserts` + `test.infinite_recursion`, folded) | `test` (27) |
| headers | 35 | 1550–1584 | `fixtures/headers.sql` + `fixtures/headers.delta.sql` (`test.get_vary_header_override()`, folded) | `headers` (34), `test` (1) |
| **content_negotiation** | **52** | **1600–1649, 12400–12401** | `fixtures/content_negotiation.sql` + `fixtures/content_negotiation.delta.sql` (**folded twice** — the vendored media-type domains + handlers on 2026-08-08, then on **2026-08-09** the octet-stream **correction**: the new `public."application/octet-stream"` domain plus `test.unnamed_bytea_param` **re-declared in place** to return that domain instead of plain `bytea`, without which case 1622 is unreachable) | `test` (52) |
| **openapi** | **39** | **1650–1688** | `fixtures/openapi.sql` (**no delta** — the v16.0 re-sync added six cases, rewrote the other 33 and touched **no** fixture object; `fixtures.sql` does not appear in `git status`) | `test` (38), `openapi_no_comment` (1 — case 1654) |
| config | 45 | 1700–1744 | `fixtures/config.sql` | `config` (45) |
| observability | 22 | 1750–1771 | `fixtures/observability.sql` (**no delta** — the v16.0 re-sync added two cases and zero fixture objects; its `.sql` change is a comment-only provenance re-pin) | `observability` (22) |
| **domain_representations** | **37** | **1800–1836** | `fixtures/domain_representations.sql` + `fixtures/domain_representations.delta.sql` (`test.evil_friends_with_column_default`, folded 2026-08-09 — the channel was opened, used and emptied inside a single pass, a first) | `domain_representations` (36), `test` (1 — case **1822**, and the label is load-bearing: see **Label caveats**) |

Total: **762 cases**, **17 areas**, **17 fixture fragments**
(plus **8** `*.delta.sql` write channels, all currently **comment-only** —
re-verified mechanically this pass: stripping comment and blank lines leaves zero
lines in every one of the eight. Each carries a single
`-- Folded into ../fixtures.sql on <date> …` provenance line and no DDL. **Three**
are dated 2026-08-08 (`headers`, `ordering`, `rpc`); **five** are dated 2026-08-09
(`content_negotiation`, `url_grammar`, `errors`, `operators`, and — new —
`domain_representations`). **There is still no
`mutations.delta.sql` and no `representations.delta.sql`.** See
[`fixtures/README.md`](fixtures/README.md) for who may write which file).

**The domain_representations re-sync DID add a fixture object**, unlike the three
passes before it. `test.evil_friends_with_column_default`
(`id public.devil_int DEFAULT 420, name text`) lands in `fixtures.sql` section 4
beside its sibling `test.evil_friends`; no seeds, no GRANT, no name collision.
It exists to make one precedence rule observable — with `Prefer: missing=default`
the **COLUMN** default (420) beats the DOMAIN default (666), which case **1822**
asserts and case **1814** contrasts against `test.evil_friends`, whose column
carries no default of its own. **Read the `schema: test` label on 1822 before
moving it**: the loader view-mirrors this table into the area schemas like any
other `test` relation, and an auto-updatable view resolves the missing INSERT
column against the *view's* `devil_int` default first — so the mirror answers
**666** and the base table answers **420**. The mirror is not wrong, it is a
different question, and only the base table expresses upstream's.

**`content_negotiation.delta.sql` is the first channel to be folded TWICE, and
its second fold is the first in the tree to CHANGE an existing definition rather
than append a new object.** `test.unnamed_bytea_param(bytea)` was transcribed
into `fixtures.sql` as `RETURNS bytea`; upstream declares it
`returns "application/octet-stream"` — the mime-named **DOMAIN**
(`schema.sql#L2372`). The return type is the *only* thing that registers an
octet-stream handler (`SchemaCache.hs#L1016` ships json/csv/geo+json/`*/*` and
nothing else), so under the old transcription case **1622** could not reach its
200 at all: it would negotiate to 406/PGRST107. The fold adds
`public."application/octet-stream"` (section 3c) and re-declares the routine in
place (section 6). **Read the fold note in `fixtures.sql` before assuming this
made anything green** — it says so plainly: 1622 was *already* passing, because
`lib/bier/rpc.ex:288` offers octet-stream for any scalar RPC result regardless
of return type, which is precisely the over-permissive behavior the **new** case
1623 was written to catch. The fold is upstream-fidelity groundwork that keeps
1622 reachable once `lib/` narrows handler discovery; it is not a green-maker.
Deliberately **no** aggregate over the new domain and **no** GRANT, which is
what keeps 1623 (`test.add_them`, scalar) and 1624 (`test.get_lines`, SETOF —
excluded by the discovery query's `NOT proretset`) at 406.

**The mutations re-sync added no channel and no fixture object either**, and its
band is where that constraint bites hardest. `fixtures.sql` does not appear in
`git status`. All 17 new cases run against relations the consolidated fixture
already had — but **the `mutations` schema is a view mirror of `test` except for
ten relations** the loader replaces with independent real tables (`items`,
`articles`, `complex_items`, `tiobe_pls`, `simple_pk`, `no_pk`, `single_unique`,
`compound_unique`, `safe_update_items`, `safe_delete_items`;
`isolate_mutations/1`, `lib/mix/tasks/bier.fixtures.load.ex:541-544`, a
**hard-coded** list that no fixtures delta can extend). Ten of the seventeen new
cases target relations outside it — `menagerie` (11402), `json_table` (11403),
`car_models` (11408, 11409, 11414), `only_pk` (11410, 11411), `tasks`/`projects`
(11412), `students`/`students_info` (11413), `users` (11415) — so nine of them
write through auto-updatable views onto the shared `test.*` tables and are
contained only by the conformance server's `db_tx_end: :rollback`
(`test/support/conformance_server.ex:194`); 11409 expects a 405 and never reaches
the database. **Read that before adding a mutations case**: the dependency is
inherited silently, and the area's remaining gaps mostly need relations that must
be *real tables* under `mutations`, which is a loader change rather than a delta.
See [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → mutations*.

**The rpc re-sync added no channel and no fixture object.** `fixtures.sql` does
not appear in `git status`; `rpc.delta.sql` is unchanged from the `test."true"()`
fold. All three new cases run against routines the consolidated fixture already
had — `rpc.ret_void` (1441, shared with 1409) and `rpc.variadic_param` (1442,
shared with 1415/1416) — or, for 1443, against the deliberate *absence* of
`test.sayhell` beside the present `test.sayhello`. Its audit's three
fixture-blocked findings were left **open and recorded** rather than
approximated; see [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → rpc*.

> **Fixture provenance, changed since the last revision.**
> `fixtures/rpc.sql` was re-pinned from `blob/v14.12` to `blob/v16.0` (commit
> `6b25f05`, comment-only, after re-verifying all 23 vendored routines at v16.0).
> It is the **second** fragment re-pinned, after `observability.sql`. **Six**
> fragments still carry **43** `v14.12` provenance URLs — `ordering.sql` 27,
> `errors.sql` 5, `auth.sql` 4, `mutations.sql` 3, `config.sql` 2, `filters.sql`
> 2. See [`../COVERAGE.md`](../COVERAGE.md) → follow-ups 14 and 24.

Each area's `feature:` prefix matches its area name exactly, so the area is
recoverable directly from the case file:

```sh
grep -h '^feature:' spec/conformance/cases/1800_format_single_domain_column.yaml
# feature: domain_representations/read/format_single_column
```

## Label caveats

- **RESOLVED this pass, and it was the openapi re-sync's largest single
  correction.** The three labels `openapi`, `openapi_no_schema_comment` and
  `openapi_variadic` named schemas that **do not exist on disk** —
  `mix bier.fixtures.load` creates none of them, and every object the openapi
  cases assert over lives in `test`. All 33 openapi cases that carried one have
  been relabelled: **31** `openapi` → `test`, **1** `openapi_variadic` → `test`,
  and case **1654** `openapi_no_schema_comment` → **`openapi_no_comment`**, which
  *does* exist (`fixtures.sql#L247`, granted at `#L2002`) and is the only schema
  its variant instance exposes. The band's label distribution is now
  `test` (38) + `openapi_no_comment` (1).

  > **Why this was not cosmetic.** The harness turns any label other than
  > `nil`/`public`/`test` into an `Accept-Profile: <label>` request header
  > (`test/support/http_case.ex#L60-71`), so those 33 cases shipped
  > `Accept-Profile: openapi`. PostgREST generates the root document **for the
  > requested profile** — upstream asserts exactly that, at
  > `IgnorePrivOpenApiSpec.hs#L49-58` (tables) and `#L81-89` (functions) — so
  > against a faithful implementation every path and definition assertion in the
  > area would have been read out of an **empty** document. They passed only
  > because Bier dispatches the root path before resolving the profile and builds
  > from `hd(db_schemas)`. **A spec must not depend on that.** `test` is also the
  > faithful label: upstream's `OpenApiSpec` runs under
  > `configDbSchemas = ["test"]` (`SpecHelper.hs#L151`) and issues a bare
  > `get "/"`, which is what the harness's suppression of the `test` label
  > reproduces on the wire.
  >
  > A prior machine verification listed `openapi -> openapi` among its unknown
  > label schemas, and the loader's own comment
  > (`lib/mix/tasks/bier.fixtures.load.ex:28-34`) confirms the absence is
  > **intentional**: "function-heavy areas (rpc, openapi, headers) are
  > intentionally NOT mirrored". The finding stayed open across four passes
  > because nothing failed. See [`../COVERAGE.md`](../COVERAGE.md) →
  > *Open verification findings* → item 2, which tracked the downstream symptom
  > (case **1652** able to return 406 for two different reasons) and is now
  > closable on the label half.
- **`multi`** is not a schema either — it stands for the `v1`/`v2` profile pair
  routed by `db_profile_default` / `db_profile_schemas`
  (`test/support/conformance_server.ex:184-185`). All the relations these cases
  target (`parents`, `children`, `get_parents_below`) exist in both `v1` and
  `v2`; case 1024 deliberately targets one that exists only in `v2`.

  > **Where the label is actually resolved matters, and it is not the harness.**
  > `multi` is neither a DB schema nor a `db_schema_aliases` key; it resolves
  > only because **implementation code** carries a hard-coded allowlist of
  > conformance labels — `@profile_aliases ~w(headers multi)` at
  > `lib/bier/plugs/action_controller.ex:479`, consumed at `:504`. Re-verified on
  > disk this pass.
  >
  > **Six cases, not four, actually send the label.** The harness injects
  > `Accept-Profile` with `Map.put_new`, so a case escapes the injection only by
  > spelling out **`Accept-Profile`** itself — spelling out `Content-Profile` is
  > not enough. Of the fourteen `multi` cases, **1005, 1006, 1007, 1008, 1011 and
  > 1012** receive `Accept-Profile: multi` (re-derived mechanically at the
  > 762-case state). Three of the six expect success (**1005**/**1008** → 200,
  > **1011** → 201) and so depend on the allowlist. Recorded in
  > [`../COVERAGE.md`](../COVERAGE.md) → *Open verification findings*: a genuine
  > finding, not a bookkeeping note, because 1008's own `notes:` claim "no
  > `Accept-Profile` header" while the harness always sends one.
- **`unicode`** aliases the schema `تست` via `db_schema_aliases`
  (`test/support/conformance_server.ex:181`); **`test`**, `public` and `null`
  suppress the `Accept-Profile` header entirely.
- **`headers` is never actually applied on case 1574.** The harness sets
  `Accept-Profile` with `Map.put_new` (`test/support/http_case.ex:69`), so a case
  that spells the header out itself wins over its label. 1574 sends
  `Accept-Profile: SPECIAL "@/\#~_-` explicitly, and relation `names` exists in
  that schema (confirmed by direct catalog query this pass). **Fifteen** cases
  override their label this way in total — re-derived mechanically: **1009, 1010,
  1011, 1012, 1013, 1014, 1017, 1018, 1023, 1024, 1558, 1559, 1560, 1574, 1583**
  — of which **twelve** spell out `Accept-Profile` (the suppressing header) and
  **three** only `Content-Profile` (**1011, 1012, 1559**), which does **not**
  suppress the injection.
- **`ordering` appears under `url_grammar`** (case 1028, the legacy embed
  target-name case, reuses the ordering fixture set), and **`test` appears under
  `rpc`** (four cases, re-derived on disk: **1433**, **1439** and **1443**, whose
  PGRST202 envelopes qualify the message with the requested schema, and **1440**,
  whose `test."true"()` routine was folded through `rpc.delta.sql` and so lives in
  `test`), **under `headers`** (case 1576) and **under `ordering`** (cases 1227–1228, the
  computed-relationship related orders — the `computed_designers` /
  `computed_videogames` functions live in `test` and the `ordering` view mirror
  does not carry them).
- **`mutations` appears under `ordering`** (case 1230, `order=` applied to a
  PATCH's returned representation). The `ordering` schema is a read-only view
  mirror of `test`, so the write goes to the loader-isolated `mutations.no_pk`
  real table; the case's `feature:` prefix (not its label) is what puts it in
  the ordering area.
- **`test` appears under `domain_representations`** — exactly once, case
  **1822**, and it is the tree's first label chosen to *avoid* the area's own
  mirror rather than to reach an object the mirror lacks. **Read this before
  "fixing" it to `domain_representations`.** The relation
  (`test.evil_friends_with_column_default`) exists in both places and both
  requests succeed; they simply answer differently. `id` is `public.devil_int`
  (`integer DEFAULT 666`) and the COLUMN adds `DEFAULT 420`. With
  `Prefer: missing=default` the column is left out of the INSERT target list, and:
  - against the **base table**, PostgreSQL applies the **column** default → **420**
    (upstream's assertion, and what the case expects);
  - against the **area mirror** (`CREATE VIEW … AS SELECT * FROM test.…`), the
    missing column is resolved against the *view's* column first, where the DOMAIN
    default is found and written as an explicit value → **666**.

  Verified both ways against a freshly loaded `bier_test`. The label is also the
  faithful one: upstream's `db-schemas` for this block is plain `test`. **A view
  mirror cannot express this behavior at all**, so if the area ever needs its own
  writable isolated relations, the loader would have to build them as REAL TABLES
  the way `isolate_representations` / `isolate_mutations` already do — a loader
  change, not a fixtures delta. Recorded in `domain_representations.yaml`'s
  `loader_exposure` gap entry.
- **The whole errors area carries `schema: test`**, including cases **1523**
  (`POST /infinite_inserts`) and **1524** (`GET /infinite_recursion`), whose
  objects were folded through `errors.delta.sql`. Both were created in `test`,
  and the loader's area-schema mirroring reproduces them as views in the seven
  mirrored schemas without error — a self-referential view definition is not
  re-planned at `CREATE VIEW` time.

### Fixture-name collision worth knowing: `menagerie` vs `menagerie_empty`

Four **pagination** cases — **1258, 1264, 1266 and 1268** — request
`/menagerie_empty`, a path that appears nowhere upstream. This is deliberate.
Upstream's `menagerie` in `RangeSpec.hs` is the pagination fixture's
single-column **empty** table, but `openapi.sql` contributes a 7-column
type-mapping table of the same name. The consolidated `fixtures.sql` keeps
openapi's as `test.menagerie` and renames the empty one to
`test.menagerie_empty` (`fixtures.sql:75-79`, `:719-722`). All four cases assert
behavior over an **empty** relation (`Content-Range '*/*'`, `*/0`, an offset past
the end), so they were retargeted during the v16.0 pagination re-sync; before
that they pointed at the 7-row type-mapping table and asserted the wrong thing.
Both relations exist in the loaded DB, and each of the four records the collision
in its own `notes:`.

## Cross-area ownership caveat

`Prefer:` coverage is split across areas by design — `headers` owns the header
semantics, `mutations` owns the table-flavored `max-affected` cases
(1390–1392), and `spec/rpc.yaml` delegates the *generic* RPC flavor of both
`handling` and `max-affected` to the headers area rather than duplicating it.

**Partly resolved by the rpc re-sync.** The one rule that is genuinely
RPC-specific rather than a flavor of a generic preference — `PGRST128`
("Function must return SETOF or TABLE when max-affected preference is used with
handling=strict"), decided in `callReadPlan` from the routine's return type —
is now modelled as `rpc.prefer.max_affected.returns_single` and asserted by case
**1441**, the tree's only PGRST128 assertion. What remains delegated and
therefore still **uncovered**: the RPC flavor of `Prefer: handling=strict`
(PGRST122 on `POST /rpc/overloaded_unnamed_param`, `HandlingSpec.hs#L35`) and
the *count* form of RPC `max-affected` (PGRST124 when a set-returning routine
affects more rows than requested, `MaxAffectedSpec.hs#L86`) — no case in any
band exercises either against `/rpc/*`.

The pagination re-sync made this a **three-way** split rather than resolving it:
new cases **1286** (`count=exact` echoed as `Preference-Applied` on a plain read)
and **1288** (`count=none, handling=strict` → 400 PGRST122) put `Prefer`
assertions in the *pagination* band too. They are correctly placed — the
preference they exercise is `count`, which pagination owns — but 1288 is now the
tree's second table-flavored `handling=strict` assertion, sitting outside the
area that models `handling`. Recorded in
[`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → headers*; when closing the two
residual RPC gaps above, decide the owning band first so the delegation stops
being circular. (Case 1441 broke the circularity only for PGRST128, and only
because that rule has no table flavor to delegate: it lives in the rpc band on
purpose, which is why the rpc area now carries a `prefer` sub-feature.)

The same pattern applies to **`PGRST127`** (aggregates rejected inside a to-many
spread), which — unlike PGRST128 — really is asserted by no case and modelled by
no area file. It belongs to `select`; see
[`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → select*.

> Re-checked at the 762-case state: `grep -rl PGRST128 spec/` matches
> `rpc.yaml` (entry `rpc.prefer.max_affected.returns_single`),
> `conformance/cases/1441_rpc_max_affected_returns_single.yaml`, this INDEX and
> `COVERAGE.md`. `grep -rl PGRST127 spec/` still matches exactly two files —
> `COVERAGE.md` and this INDEX, i.e. only the documents recording the gap; no
> case and no area model mentions **PGRST127**.

A third split needed the same care and is **now half-resolved, by example.** The
`in.( … )` **value grammar** is url_grammar's (its docs page owns the *Reserved
characters* section), the `in` operator's **SQL rendering** is claimed by
`operators.yaml`, and the `in.()` **empty set** was raised as a gap against
`filters`. It was closed by **operators** — cases **10200–10205** in the 10200+
band, together with the folded `test.items_with_different_col_types`.

That is the right resolution on the evidence: `operators.yaml` already modelled
the `[""] -> "= ANY('{}')"` branch that *produces* the behavior, and the pass
extended that model with the `lexeme` whitespace rule rather than duplicating it
in filters. It also avoided filters' full primary band. **The general lesson is
worth more than the outcome**: a gap in [`../COVERAGE.md`](../COVERAGE.md) is
filed under the area that *noticed* it, which is not reliably the area that can
close it. Check a gap against disk before costing it.

What remains unsettled: url_grammar's **escaped-char** `in.( … )` values
(`\"`, `\\`) and the general value grammar. Decide the band before authoring, and
note that `filters`' primary band 1150–1199 is full (overflow `[10600..10799]`),
`operators`' 1050–1099 is full (overflow 10237+ in use but undeclared),
**`content_negotiation`'s 1600–1649 is now full too (overflow 12402+ in use but
undeclared)**, and **`rpc`'s 1400–1443 is nearly full (only 1444–1449 free)**,
while url_grammar's 1036+, ordering's 1233+, errors' 1527+ and pagination's 1289+
are free.

### A fifth split, opened by the mutations pass — and it points both ways

The PGRST114 rule "limit/offset querystring parameters are not allowed for PUT"
is now asserted **four times across two areas, from the same two upstream
it-blocks**:

| Rule | url_grammar | mutations | Upstream |
|------|-------------|-----------|----------|
| `limit` on PUT | **1016** (`schema: test`) | **1383** (`schema: mutations`) | `UpsertSpec.hs#L295` |
| `offset` on PUT | **1030** (`schema: test`) | **1399** (`schema: mutations`) | `UpsertSpec.hs#L302`/`#L303` |

All four issue the *identical* request (`PUT
/tiobe_pls?name=eq.Javascript&{limit,offset}=1`) and expect the *identical*
four-key envelope. They differ only in the `schema:` label and in how much
mechanism their `notes:` explain — 1016/1030 cite `ApiRequest.hs#L178`,
`Error.hs#L111/#L158/#L185` and `QueryParams.hs#L152`'s `offset`→`limit` rewrite;
1383/1399 do not.

**The mutations pass did not create this, but it completed it** — 1383 already
twinned 1016 — and it did so in the same diff in which it **deleted** case
**11406** for duplicating representations case 1332. Two opposite calls, twenty
ids apart, with no rule on disk distinguishing them. Settle it once
([`../COVERAGE.md`](../COVERAGE.md) → follow-up 26): either one it-block means one
case owned by the area that models the rule, or per-label duplication is
deliberate fixture-set coverage and both models should say so.

### A fourth ownership question, opened by the rpc audit

Three of the rpc area's five open findings need fixture routines, and the
constraint on them is **ownership**, not absence. `spec/conformance/fixtures/rpc.sql`
is a *human-owned live loader input* that no workflow agent may edit
(`spec/rpc.yaml` → `loader_exposure`, [`fixtures/README.md`](fixtures/README.md)),
so a spec pass can only reach `rpc.delta.sql` → `fixtures.sql` → schema `test`.
That is why case **1440** carries `schema: test` rather than `schema: rpc`, and
it worked — but 1440 was one zero-argument routine, and the open findings need
eight objects (`returns_record` and its three variants, an array-echoing
`varied_arguments`, `unnamed_text_param`, `unnamed_xml_param`,
`unnamed_int_param`). **Decide once whether the delta path is blessed for these
or whether they belong in `rpc.sql` via a reviewed human commit** —
[`../COVERAGE.md`](../COVERAGE.md) → follow-up 22.

## Per-area sub-feature breakdown

The `feature:` field is a slash-delimited path `<area>/<sub-feature>/...`. The
sub-features present per area (second segment, as on disk):

| Area | Id band | Sub-features |
|------|---------|--------------|
| url_grammar | 1000–1035 | method (incl. the OPTIONS `Allow` matrix on a table 1019, a VOLATILE routine 1031, a STABLE routine 1032 and the root path 1033), path (incl. OPTIONS on an unknown relation -> 404, 1034), percent-encoding (incl. `%20` in both a relation and a column name, 1035), profile, reserved-params (`limit` **and** `offset` forbidden on PUT, 1016/1030), reserved-characters |
| operators | 1050–1099, 10200–10236 | eq (incl. whole-range and whole-array equality), neq (incl. the null-propagating array form), lt/lte/gt/gte, in (incl. the **empty set** `in.()` / `not.in.()` / whitespace-only / blank-element-400 group), is, like/ilike, match/imatch, fts/plfts/wfts/phfts (incl. the `(language)` modifier on all four, the **automatic `to_tsvector()` coercion** against text/jsonb/domain/recursive-domain/computed-field targets, and the tsquery `&`/`\|`/`!` and websearch `and`/`or`/`-` operand grammars), cs/cd/ov, sl/sr/nxl/nxr/adj, isdistinct (incl. range and array operands, and its null-safe contrast with neq), not (incl. three more logic-tree shapes), quantifier (any/all, incl. `gte(all)`/`lte(all)`) |
| select | 1100–1149 | columns, alias, cast, alias-and-cast, json-path, composite, array, computed-column, computed-relationship, embed (incl. one-to-one, the v16 alias/legacy-target-name rules and the `table!fk` hint), spread, aggregate |
| filters | 1150–1199 | horizontal, logical, not, json, quoting, embed |
| ordering | 1200–1232 | direction, nulls (incl. alongside limits, 1229), json_path, computed_column, multi_column, composite, related (incl. computed relationships, 1227–1228), embed, mutation_representation (1230, `schema: mutations`), rpc (1231–1232), error |
| pagination | 1250–1288 | limit_offset (incl. HEAD 1277 and the POST-`/rpc/`-with-query-params flavor 1281), range_header (incl. past-the-last-item with count 1278, open-ended non-zero offset 1279, the GET-`/rpc/` flavor 1280, the **method scoping** pair 1284/1285 and the **intersection-not-override** case 1287), count (incl. `count=planned` on an RPC yielding no total 1283, `Preference-Applied` echoed 1286, and `count=none` rejected under `handling=strict` 1288), embedded (**limit only** — `.offset` has no case; see [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → pagination*), content_range (1282, the empty-window envelope on an RPC) |
| representations | 1300–1327, 1330–1333 | post (13, incl. the two headers-only Location suppressions — bulk insert 1315 and no-PK relation 1317 — plus the return=representation-never-carries-Location rule 1316), patch (5), delete (5), put (4), **prefer** (3 — duplicate-token-first-wins 1318, unknown-token-ignored 1319, fixed `Preference-Applied` order 1327), **read** (1 — 1325, `return=` not echoed on a GET), **rpc** (1 — 1326, the same on a `POST /rpc/`, the area's only `schema: rpc` case) |
| **mutations** | **1350–1399, 11400–11405, 11407–11415** | insert (incl. the `x-www-form-urlencoded` body 11402, insignificant whitespace 11403, the empty-body PGRST102 1398 and the unique-violation 409/`23505` 11401), update (incl. the multi-row 204 + `Content-Range` 11400 and the one-to-one / m2m **resource-embedding** representations 11413/11415), delete (incl. the to-one parent embed 11412), upsert (incl. the only-pk-table merge/ignore pair 11410/11411, composite-pk POST/PUT 11414/11408, the partial-composite-pk PGRST105 11409, `PUT` ignoring `Range` 11407, ignore-duplicates-with-nothing-created 11404 and the PUT-`offset` PGRST114 1399), columns-param (**POST and PATCH only** — the PUT claim was withdrawn as uncited), missing-default, safe-update, safe-delete, max-affected (incl. the UPDATE flavor 11405). **No new sub-feature was minted**: the four review-driven embedding cases live under `update` and `delete` rather than an `embed` sub-feature |
| **rpc** | **1400–1443** | return, setof, args (incl. the form-urlencoded variadic POST 1442), method, content-negotiation, count, shape, error (incl. the closest-proc PGRST202 hint 1443, the byte-length-pinned complement of the bare-404 probe 1432), overloaded, single-unnamed-param (**json flavor only** — text and xml have no case), name, **prefer** (**1441**, the RPC-only PGRST128 rule — the tree's only assertion of that code). **No sub-feature exists for untyped (`record` / `SETOF record`) returns, non-variadic array parameters, or resource embedding through a table-valued function**; see [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → rpc* |
| auth | 1450–1499, 11800–11818 | anonymous, claims, role, role-claim-key, role-switching, jwt, audience, pre-request, guc, rpc |
| errors | 1500–1526 | sqlstate (incl. the two 5xx paths 1523/1524), pgrst_code (incl. the PGRST205 fuzzy-hint pair 1520/1521), raise, headers (incl. the `Proxy-Status` custom-code case 1519), verbosity (incl. the inline-416 case 1522), envelope (1525, byte-exact key emission order), proxy_status (1526, absent on the inline 416) |
| headers | 1550–1584 | prefer, profile, location, content-location, guc, vary |
| **content_negotiation** | **1600–1649, 12400–12401** | json, csv, geojson, octet-stream (incl. the **negative** 1623 — a scalar RPC with no media-type domain is not negotiable as octet-stream — alongside the SETOF flavor 1624), singular, nulls-stripped (incl. the mutation-representation pair **12400**/**12401** and the explicit-`select=` singular 1649), plan, openapi, precedence, error (incl. the unparsable-media-type echo 1647), custom-media-handler, **case-insensitivity** (1648). The band is 1600–**1649**, not 1646: 1647/1648/1649 and the overflow pair 12400/12401 are on disk |
| **openapi** | **1650–1688** | root (10 — incl. the document's own `/` path item **1687** and the document-level `produces`/`consumes` list **1688**, both anchored at the generator because no upstream Feature it-block reads either), rpc (8 — incl. the all-OUT args schema that emits neither `properties` nor `required` **1683**, its INOUT-with-no-DEFAULT complement **1684**, and the IMMUTABLE half of the volatility switch **1685**), table (5 — incl. the shared `preferParams` definition and its **suppressed empty enum** **1686**), comments (5), types (4), mode (4), security (2), defaults (1). **No sub-feature exists for the `/rpc/*` per-operation `produces`/`responses` pair or for `$.parameters.on_conflict`**; see [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → openapi* |
| config | 1700–1744 | dump-config, sources, aliases, validation, coercion, parsing, precedence, db-max-rows, db-tx-end, db-extra-search-path, app-settings, server-cors-allowed-origins, cli, client-error-verbosity, server-reuseport, url-use-legacy-target-names, admin-server-unix-socket |
| observability | 1750–1771 | server-timing (incl. **1770**, the exact five-metric render), trace-header, log-level, server (**1771**, the `Server: postgrest/…` version header — the tree's only `Server:` assertion) |
| **domain_representations** | **1800–1836** | **write** (18 — the area's largest sub-feature after this pass, and all but four are new: headers-only POST on a table **1823** and on the updatable view **1824**, POST-through-view formatting incl. the computed column **1825**/**1826**, `?columns=` on that view **1827**/**1836**, and the entire PATCH block **1828–1835** — single, bulk, `?columns=`, unknown column, and no-rows-matched), read (11), filter (6 — incl. **1821**, the `ilike`-on-a-datarep-column 404/`42883` that proves pattern operators are deliberately NOT wired to representations), default (2 — no-cast-uses-base-type **1814** and **column-default-beats-domain-default 1822**, the area's only `schema: test` case). **No sub-feature exists for data representations in the presence of COMPUTED RELATIONSHIPS** (upstream `ComputedRelsSpec.hs#L105`), which is blocked by `Prefer: tx=commit` *and* by the single-`request` case shape; see [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → domain_representations* |

### v16.0 additions worth knowing

- **domain_representations** grew from **21 to 37** cases and is the tree's
  **seventeenth and final** audited area — ✅ *pass*, **0 citation defects**,
  **one** non-blocking missing-coverage finding, the smallest in the tree.
  **Sixteen cases added (1821–1836), three rewritten (1811–1813), one fixture
  object authored AND folded, one delta channel opened and emptied.** With this
  pass **every area carries a v16.0 verdict and every verdict reports 0 citation
  defects.** Four things about this pass are worth carrying forward:
  - **Its largest single output came from retiring a recorded gap that claimed
    the work was IMPOSSIBLE.** `domain_representations.mutation_isolation` held
    that the area's whole write half could not be modelled because the shared
    conformance instance cannot isolate mutations. It can:
    `test/support/conformance_server.ex` sets `db_tx_end: :rollback` and
    `Bier.Mutation.finish_tx/3` aborts every mutation transaction after the
    response is computed — the same isolation upstream gets from
    `configDbTxRollbackAll = True`. **The claim survived a full prior re-sync
    unchallenged.** Fourteen cases (1823–1836) came out of retiring it. If you
    read a gap entry that says a case *cannot* be written, check the harness
    before believing it.
  - **Case 1822's `schema:` label is load-bearing against its own area**, and it
    is the first case in the tree of which that is true. `schema: test`, not
    `domain_representations`, because the area's auto-updatable view mirror
    resolves a missing INSERT column against the *view's* domain default (666)
    before the base table's column default (420) can fire. Both halves were
    verified by inserting on a live database. See **Label caveats**.
  - **It is the first pass to open, use and empty a delta channel in one go.**
    `domain_representations.delta.sql` carried
    `test.evil_friends_with_column_default`, was folded into `fixtures.sql`, and
    is back to its provenance line — so the channel's *steady state* was restored
    within the pass rather than by a later one.
  - **Its `gaps:` key went 5 → 10, and three of the five new entries argue that a
    case should NOT be written** — a cross-reference handing an upstream block to
    the *ordering* area, a fixture-divergence hand-off with the exact DDL and
    blast radius a future fold needs, and a `loader_exposure` entry (a key with no
    precedent) recording the view-mirror default-resolution trap above.

- **openapi** grew from **33 to 39** cases and is the tree's **sixteenth**
  audited area — ⚠️ *revise*, **0 citation defects**, **two** missing-coverage
  findings. **Six cases added (1683–1688), 33 rewritten, one authored then
  WITHDRAWN, no fixture object, no delta channel.** Four things about this pass
  are worth carrying forward:
  - **Every one of the 33 rewritten cases changed its `schema:` label**, because
    31 of them named a schema that does not exist. That is the largest
    single-property correction any pass has made, and it is the first correction
    to a case field that is neither `source:` nor an assertion. See **Label
    caveats** above for the mechanism and why the cases passed anyway.
  - **It is the first pass to WITHDRAW a case rather than delete or reuse it.**
    Case **1689** (`openapi-server-proxy-uri` → `host`/`basePath`/`schemes`) was
    authored, found to be red for a harness reason rather than a behavior reason,
    and removed before commit — so **1689 was never on disk at HEAD and is free**.
    The behavior survives as a modelled entry with `cases: []`
    (`openapi/root/server-proxy-uri`) that spells out the case verbatim, so
    restoring it is a copy once the harness's `@variant_case_ids` list gains an
    id. **Three passes, three conventions for a dropped case**: mutations left
    11406 permanently vacant, content_negotiation reused 1623, openapi freed 1689
    without ever consuming it. See [`../COVERAGE.md`](../COVERAGE.md) →
    follow-up 26.
  - **It is the first pass to REMOVE non-empty `preconditions:`** — both of the
    area's two, both of which were wrong. See the `preconditions:` note below.
  - **It wrote the tree's second `fixture_notes:` key** (five entries), following
    content_negotiation's precedent without a fixture defect to prompt it. Its
    subject is declarations the cases read but never write: `test.jwt_test`'s
    missing volatility keyword (which is why case **1685** uses
    `test.three_defaults` and not upstream's routine), `test.root()`'s plain
    `json` return, `test.variadic_param`'s `DEFAULT '{}'`, the argument modes of
    `many_out_params` / `single_inout_param`, and `openapi_no_comment` having no
    comment.

- **content_negotiation** grew from **47 to 52** cases and is the tree's
  **fifteenth** audited area — ⚠️ *revise*, **0 citation defects**, **seven**
  missing-coverage findings. **Six cases added (1647, 1648, 1649, the re-issued
  1623, and the overflow pair 12400/12401), one deleted, one id REUSED, three
  rewritten (1600, 1622, 1637), and one fixture object corrected.** Five things
  about this pass are worth carrying forward:
  - **It is the first pass to reuse an id.** The old **1623**
    (`octet-stream/no-charset`, a 200) was deleted and 1623 re-issued to a
    **406** negative (`octet-stream/not-registered-406`, `GET /rpc/add_them`
    under `Accept: application/octet-stream`). The deleted assertion was folded
    into case **1622** rather than dropped. See the id-reuse warning at the top
    of this page, and contrast the mutations pass's 11406, whose id was left
    vacant on purpose.
  - **It corrected a FIXTURE, which is a species this tree had not recorded.**
    Every earlier fold added objects; this one re-declared an existing routine.
    `test.unnamed_bytea_param(bytea)` returned plain `bytea` where upstream
    returns the mime-named DOMAIN, and that single transcription slip made case
    1622's assertion **unreachable** — the case could only ever have answered
    406/PGRST107 against a faithful implementation. Nothing mechanical in this
    tree could see it: the case validated, its pin was correct, its citation was
    real, and it *passed* — against a `lib/` that is over-permissive in exactly
    the way case 1623 now pins.
  - **A modelled rule was corrected at its root: handler discovery keys on the
    RETURN TYPE, never on an aggregate's `stype`.** The model had described a
    custom media handler as "an AGGREGATE whose stype is that domain". The
    discovery query joins `proc.prorettype = <domain oid>` and
    `pg_aggregate.aggfnoid = proc.oid` (`SchemaCache.hs#L1062-L1071`), with a
    second branch for plain non-set-returning **functions** returning such a
    domain (`#L1080-L1086`). stype merely *coincides* with the return type when
    the aggregate has no finalfunc — true of every fixture here, which is why
    the wrong rule survived. Case **1637**'s notes were rewritten with it.
  - **Two claims were weakened to what their citations actually support.**
    "negotiateContent's body is **byte-identical** to v14.12's" became
    identical **modulo whitespace** (v16.0 re-aligned the `case` alternatives);
    and "**NEW in v16.0**: the JSON plan includes a Query Identifier field"
    became "upstream **added a test** at v16.0", since the field is emitted by
    PostgreSQL's `EXPLAIN (VERBOSE, FORMAT JSON)` when `compute_query_id` is on
    — PostgREST introduced nothing, and the old wording contradicted this
    model's own `version_delta.behavior_changes: []`.
  - **Case 1600's `source:` moved OFF implementation code** (`MediaType.hs#L69`
    → `RawOutputTypesSpec.hs#L15`), joining 1189/1016/1767 in that direction.
    The tree's implementation-anchored total is **unchanged at 53** only by
    coincidence: 1600 and the deleted 1623 left, the re-issued 1623 and 1648
    arrived. **Read the composition, not the total.**
  - **The model is still silent.** `content_negotiation.yaml` gained a new
    top-level `fixture_notes:` key — three entries recording exactly which
    fixture properties its cases depend on, which has no precedent in the tree
    and is worth copying — but it still carries **no `gaps:` key under any
    name**, so all seven audit findings live only in
    [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → content_negotiation*.
- **representations** grew from **24 to 32** cases, filling **1315–1319** and
  **1325–1327** inside its existing band (no new band, no fixture object, no
  `representations.delta.sql`). **Eight cases added, one rewritten (1309), none
  deleted**, and the model gained its **first `gaps:` key** — five entries. Three
  things about this pass are worth carrying forward:
  - **It is the tree's third ✅ *pass* verdict** (after `errors` and `operators`)
    and the **first pass verdict on an area that had no gap list at all**, which
    retires the last clean instance of "silence = never examined". Its audit
    produced **0 citation defects** and its findings were closed inside the pass.
  - **It broke the implementation-anchored plateau, and by the largest single-pass
    jump in the tree's history.** Seven of the eight new cases anchor at
    `src/library/PostgREST/…` rather than an upstream `it`-block — **1315**/**1317**
    at `Query/Statements.hs#L48`/`#L49` (the two Location suppressions), **1318** at
    `ApiRequest/Preferences.hs#L100`, **1319** at `Plan.hs#L207`, **1325**/**1326**
    at `Response.hs#L283`/`#L281`, **1327** at `Preferences.hs#L179`. Only **1316**
    cites a Feature spec (`InsertSpec.hs#L228`). The count went **46 → 53** after
    three flat passes and the share **6.3 % → 7.2 %**. That is not a defect — every
    one of the seven pins a rule upstream never asserts black-box — but it is the
    single biggest movement in that metric and each case says so in its `notes:`.
  - **One `source:` anchor was corrected in a fourth direction: away from a real
    it-block that proved a *weaker* claim.** The model had cited
    `InsertSpec.hs#L745` for "a POST without `return=headers-only` carries no
    Location". That block lives under `describe "Inserting into VIEWs"` and posts
    to `/compound_pk_view`, so it proved the rule for a **view** only; the model
    now cites `#L157` (no-Prefer, on the `projects` TABLE) and `#L99`
    (`return=representation`). Case **1309** was rewritten for the same reason.
    The old anchor was real, fetchable and correctly pinned — the defect was
    *scope*, which no mechanical check in this tree can see.
- **mutations** grew from **48 to 65** cases, opening the tree's **third** 5-digit
  band at **11400–11415** after 1398/1399 filled the primary 1350–1399. **One
  case was rewritten (1352), seventeen added, one authored and deleted (11406),
  and no fixture object created.** Three things about this pass are worth
  carrying forward:
  - **Its audit was partly closed inside the pass.** Four cases —
    **11412** (`DELETE /tasks?id=eq.8&select=id,name,project:projects(id)` → the
    to-one parent, `DeleteSpec.hs#L71`), **11413** (`PATCH
    /students?id=eq.1&select=name,students_info(address)` → one-to-one,
    `UpdateSpec.hs#L579`) and **11415** (`PATCH
    /users?id=eq.1&select=name,tasks(name,project:projects(name))` →
    many-to-many with a nested parent, `UpdateSpec.hs#L539`), plus the pre-existing
    representations case 1300 for POST — exist because the review asked for the
    **mutation flavor of resource embedding**, which no case covered. They
    transcribe upstream's exact seed values with no derivation.
  - **A modelled rule was WITHDRAWN, not corrected.** `mutations.yaml` had claimed
    `?columns=` applies to **PUT**. Nothing at v16.0 asserts it — every
    `columns=` in `UpsertSpec.hs` is a POST, and the PUT docs say the opposite
    ("All the columns must be specified in the request body, including the primary
    key columns", `tables_views.rst#L689`). `applies_to` now reads
    `[POST, PATCH]`. **Note the failure mode**: this was not a stale-version
    claim, so no pin sweep could have found it — an unexercised model entry is
    unverified by construction.
  - **One `source:` anchor moved sideways**: case **1352** from
    `InsertSpec.hs#L218` (the *single-object* no-pk it-block) to **`#L268`**
    (`context "with bulk insert"` / `it "returns 201 but no location header"`),
    because 1352 is a bulk insert and had been citing an assertion about a
    different request shape. The old anchor was real, fetchable and correctly
    pinned — which is why nothing mechanical had caught it.
  - Its **gap list nearly doubled, 6 → 11**, and the new entries are
    relation-blocked rather than un-researched: `foo` (GENERATED ALWAYS, the
    area's one genuine v14.12→v16.0 behavior change), `UnitTest` (case-sensitive
    identifier), `employees`, `web_content`, `artists`/`albums`, the three
    `surr_*_upsert` tables, and a dozen more. Several must be **real tables**
    under `mutations`, which the loader's hard-coded `isolate_mutations/1` list
    controls — so a fixtures delta alone cannot close them.
- **rpc** grew from **41 to 44** cases, extending its band to **1400–1443**
  without a fixture object — `rpc.delta.sql` stays a comment-only placeholder
  after `test."true"()` (case 1440) was folded, and `fixtures.sql` was not
  touched. **Six existing cases were rewritten** (1402, 1422, 1432, 1433, 1439,
  1440) and **zero `source:` anchors moved**, which is worth noting because
  rewriting a case is historically where anchors move.
  - **1441** opens a new sub-feature for the area, **prefer**: `POST /rpc/ret_void`
    with `Prefer: handling=strict, max-affected=20` → **400 PGRST128**. This is
    the *only* PGRST128 assertion in the tree; the code is RPC-specific
    (`failMaxAffectedRpcReturnsSingle` in `Plan.hs`, decided in `callReadPlan`
    before the routine runs) and is distinct from the table-flavored **PGRST124**
    that mutations/headers own via 1390–1392 and 1555–1556. It substitutes the
    already-loaded `ret_void` for upstream's `delete_items_returns_void`, and the
    substitution is argued in the case's own `notes:` — the check reads only the
    return type and the `Prefer` header, never the arguments.
  - **1442** pins the form-urlencoded variadic POST (`v=hi&v=there` →
    `["hi","there"]`), the third binding path for one param alongside 1415
    (JSON array body) and 1416 (repeated query params).
  - **1443** closes the half of `rpc.notfound.unknown_proc` that had no case: the
    closest-proc **PGRST202** hint for `GET /rpc/sayhell`, asserted as the full
    four-key envelope *and* upstream's own `Content-Length: 291`. It carries
    `schema: test` (like 1433) because PGRST202 qualifies its text with the
    requested schema; case **1432** stays a bare-404 probe, which is the
    deliberate contrast upstream draws with the 0.75 fuzzy threshold.
  - **Its audit verdict is ⚠️ revise with five findings and 0 citation defects —
    the most any single area audit has produced.** Two of the docs page's own H2
    sections (*Untyped functions*; *Functions with array parameters*) have no
    case, no model entry and no gap note; the `text/plain` and `text/xml` flavors
    of the single unnamed parameter are absent while only the bytea flavor is
    covered (and from `content_negotiation` — **case 1622 alone** now that 1623
    has been re-issued as an unrelated 406 negative); resource embedding
    through a table-valued function is exercised only incidentally by case 1023
    in the `url_grammar` band; and `?columns=` on an RPC POST has no case
    anywhere. **A freshly re-synced area is not a covered area.** See
    [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → rpc*.
- **operators** grew from **50 to 87** cases — the largest single-area delta of
  any re-sync. **37 ids are new (10200–10236, a second 5-digit band) and zero
  existing cases were rewritten.** Its audit verdict is **✅ pass** — the tree's
  second, after errors — with **0 citation defects**. What it found was not a
  wrong rule but two *silences*:
  - **The `IN`/`NOT IN` empty set — a gap this tree had filed under *filters*,
    closed from the operators side.** Cases **10200–10202**
    (`?int_data=in.()`, `?text_data=in.()`, `?bool_data=in.()` → `[]`),
    **10203** (`?int_data=not.in.()` → **all** rows, NULLs included — `= ANY` over
    a zero-element array is an empty OR, i.e. FALSE whatever the left operand, so
    its negation needs no `IS NOT NULL` guard), **10204**
    (`in.(    )`, whitespace consumed by `lexeme`) and **10205**
    (`in.( ,3,4)` → **400** / `22P02`: a blank element alongside real ones is
    *not* collapsed). This is the first time a re-sync closed a gap recorded
    against a different area — see *Cross-area ownership caveat* above.
  - **The automatic `to_tsvector()` coercion — an entire upstream `context` block
    that existed at BOTH pins with zero coverage.** An fts/plfts/phfts/wfts filter
    does **not** require a tsvector column: when the target field's *base* type is
    anything else, `Plan.hs` tags it `ToTsVector lang` and `pgFmtField` emits
    `to_tsvector(<lang>, <field>)` so `@@` type-checks. The exemption that clears
    the tag when the base type is already `tsvector` is what keeps the
    pre-existing cases (1067–1071, 1090) emitting a bare `@@` — without it they
    would compile to `to_tsvector(<tsvector col>)`, which does not type-check at
    all. Cases **10220–10227** cover text and jsonb targets and the four
    operators; **10228** a tsvector-returning **computed field**; **10229** a
    tsvector **domain**; **10230** a *recursive* domain (a domain over a domain),
    which works because introspection resolves `base_type` transitively. New
    model entry: `grammar.fts_auto_tsvector`.
  - **10231–10236** pin that the fts operand is passed to
    `to_tsquery`/`websearch_to_tsquery` **verbatim** — PostgREST parses no tsquery
    syntax of its own — via the tsquery lexeme booleans (`&`, `|`, `!`) and the
    websearch booleans (`and`, `or`, `-`).
  - **10206–10219** fill in per-operator corners: `isdistinct` on range and array
    operands and its null-safe contrast with `neq` (10206/10207/10213), whole-range
    and whole-array `eq` (10211/10212), the `gte(all)`/`lte(all)` quantifiers
    (10209/10210), and four more `not`-prefixed shapes including three inside logic
    trees (10208, 10214–10216), plus the `(language)` modifier on `plfts`/`wfts`/
    `phfts` (10217–10219), which only `fts` had (1071).
  - It was the first re-sync in three to add fixture objects, through
    **`operators.delta.sql`** — see the fixture table above. Every one of the 37
    new cases anchors at an upstream `it`-block (29 `QuerySpec.hs`, 8
    `AndOrParamsSpec.hs`), so the tree's implementation-anchored count did **not**
    move.
  - **Residual, recorded because nothing on disk says it otherwise**: upstream's
    `describe "IN and NOT IN empty set"` sweeps **eight** column types and only
    three are cased. `bytea`, `char`, `date`, `real` and `time` have no case even
    though the folded table declares all eight columns. See
    [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → operators*.
- **observability** holds its band at **1750–1771** (**22** cases, up from 20).
  Two ids are new, **six existing cases were rewritten**, and like the
  pagination pass before it this one **retracted a modelled rule** rather than
  only adding coverage:
  - **1757 / 1768 / 1769 lost their `headers_absent_in_value` assertion.** They
    previously claimed `OPTIONS` responses omit the `plan` and `transaction`
    Server-Timing metrics. PostgREST has no such behavior at v16.0 **and had none
    at v14.12**: `withTiming` branches only on `configServerTimingEnabled`
    (`App.hs#L272`), never on the action, so all five metrics are emitted.
    `Plan.actionPlan` returns `NoDb …` and `MainTx.mainTx` returns `NoDbTx`, but
    both stages are still wrapped and still produce a duration. The three cases
    now assert only what upstream asserts — presence of `jwt`/`parse`/`response`,
    `ServerTimingSpec.hs#L87-L111`, whose matcher is presence-only — and their
    `source:` anchors moved from `ServerTimingSpec.hs#L87/#L96/#L104` onto
    `App.hs#L225` / `Plan.hs#L174` / `Plan.hs#L177`, because a claim about control
    flow cannot be refuted at a spec line that never made it.
    **`lib/bier/plugs/observability.ex:159` still implements the retracted
    behavior** and must be fixed by the conformance pass — see
    [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → observability*.
  - **1770** (`server-timing/render-format`) pins the **exact wire render** that
    1750 leaves loose: `\A`/`\z`-anchored, `", "` separators, exactly one
    fractional digit per metric (`showFFloat (Just 1)`), all five metrics in the
    fixed order jwt, parse, plan, transaction, response. Its ground truth is the
    `Response/Performance.hs#L29` module **doctest** — the only place upstream
    pins the rendering at all, since `matchServerTimingHasTiming`
    (`SpecHelper.hs#L79`) accepts any separator and any number of decimals.
  - **1771** (`server/version-header`) is a **new sub-feature** and the tree's
    first `Server:` header assertion: `HEAD /` → `headers_present: [Server]` plus
    `headers_match: {Server: "^postgrest/.+"}`. Only the prefix is asserted,
    mirroring upstream, which *derives* the version from the header rather than
    hard-coding it (`test_io.py:1065`). It carries **no `config:` block** — the
    header is unconditional in `App.hs#L143` (`setServerName`), gated by no key.
    It is also the tree's **13th HEAD case, and the 13th to expect a 2xx**.
  - **1765/1766/1767** were rewritten to state in their own `notes:` that their
    `config: {log-level: …}` blocks are **inert** — `@variant_case_ids` carries
    only 1758/1763/1764 from this band, so all three run at the shared instance's
    `log_level: :error` and assert only a log-level-independent status. 1767's
    `source:` also moved *off* implementation code (`Logger.hs#L63`) onto
    `test_io.py#L523`, joining 1765/1766 on the parametrized upstream test.
  - The pass added **no fixture object**. Its change to
    `fixtures/observability.sql` is **comment-only**: the header provenance URLs
    were re-pinned from `blob/v14.12` to `raw/v16.0` (all seven anchored line
    numbers verified unchanged) and two missing lines were added for objects the
    file already created. It is the first fixture fragment in the tree re-pinned
    to v16.0.
- **pagination** holds its band at **1250–1288** (**39** cases, up from 28 in the
  pass before). Eleven ids were new, **eight existing cases were rewritten**, and
  the pass **corrected a modelled rule** rather than only adding coverage:
  - **1287** (`range_header/intersects_limit`) is the pass's headline. The model
    previously claimed "Range headers override limit/offset query params",
    citing the upstream it-block titled *"headers override get parameters"*
    (`RangeSpec.hs#L194`, case 1261). `getRanges` does **not** override — it
    computes `headerAndLimitRange = rangeIntersection headerRange limitRange`
    (`ApiRequest.hs#L185`). Upstream's shape (`?limit=3` + `Range: 0-1`) is the
    one case where intersection and override agree, so no existing case could
    catch the error. 1287 (`?limit=2` + `Range: 0-5` → 2 rows, not 6) is the
    discriminating shape, and **1261's `notes:` were rewritten** to say so — its
    filename still reads `..._overrides_params.yaml`.
  - **1284**/**1285** (`range_header/get_only_head`, `get_only_rpc_post`) pin the
    header's **method scoping**: `headerRange = if method == "GET" then
    rangeRequested hdrs else allRange` (`ApiRequest.hs#L183`, under a comment
    citing RFC 9110), with `method` the raw request method, so HEAD is *not*
    folded into GET. limit/offset query params are not method-scoped and still
    apply (1277, 1281) — the contrast is the point.
  - **1280–1283**, **1285** carry pagination onto `/rpc/` paths for the first
    time (`pagination_count.rst#L61`, "This also works on views and table
    functions"): the Range header on a GET `/rpc/` (1280), limit/offset on a
    **POST** `/rpc/` whose args are in the JSON body (1281), the `*/*`
    empty-window envelope with `Content-Length: 2` (1282, a new `content_range`
    sub-feature) and `count=planned` on an RPC producing **no total at all**
    (1283, the PAG-024 degradation).
  - **1286**/**1288** are `Prefer` assertions: `count=exact` echoed as
    `Preference-Applied` on a plain **read** (upstream only asserts it on
    mutations), and `count=none` — which is *not* a `PreferCount` constructor —
    rejected with 400 PGRST122 under `handling=strict`. Cases **1267** and
    **1268** gained `headers_absent: ["Preference-Applied"]` for the same reason.
  - **1278**/**1279** finish the Range-header edge set: the 416 route on a
    *non-empty* collection (`Range: 100-199` + `count=exact` → `*/15`) and the
    open-ended non-zero offset `Range: 10-`, whose `source:` is
    `pagination_count.rst#L52` — **the tree's only case anchored at the
    documentation** rather than at the test suite or the source.
  - **1258, 1264, 1266, 1268** were retargeted from `/menagerie` to
    `/menagerie_empty` (see *Fixture-name collision* above), and **1268**/**1269**
    had their `source:` anchors moved from the enclosing `context` line onto the
    actual assertion (`RangeSpec.hs#L160`→`#L163`, `#L152`→`#L153`).
  - **1275**'s `notes:` were substantially expanded to record that Bier's
    conformance server sets no `db-max-rows`, so `count=estimated` reports
    `max(exactTotal, plannerEstimate)` rather than the exact total; the case is
    safe only because the planner estimate happens to equal the exact count.
  - The pass added **no fixture object** and no `pagination.delta.sql`.
- **errors** holds its band at **1500–1526** (27 cases) with two sub-features
  added in the previous pass — **envelope** (1525, byte-exact key emission order,
  the only errors case citing the `test/io` tree) and **proxy_status** (1526,
  absent on the inline 416) — plus **1519** (`Proxy-Status` on a
  `RAISE 'PGRST'` custom code), **1520–1521** (the PGRST205 fuzzy-hint threshold
  pair), **1522** (`client-error-verbosity: minimal` on the inline 416) and
  **1523–1524** (the 54001 and 42P17 5xx SQLSTATE paths, the two cases that
  needed `errors.delta.sql`).
- **url_grammar** holds its band at **1000–1035** (36 cases): **1031–1033**
  complete the OPTIONS `Allow` matrix, **1034** pins OPTIONS on an unknown
  relation → 404, **1035** pins `%20` decoding in a relation *and* a column name
  (via `test."Server Today"`, folded 2026-08-09), **1030** is 1016's `offset`
  twin, **1016** was re-anchored onto `UpsertSpec.hs#L295`, and **1029**'s
  "byte-identical parser" note was corrected.
- **select** holds **1100–1149** (50 cases), introducing
  **1142** (`select/embed/hint-table-bang-fk`); **1143–1144** and **1145–1146**
  (composite- and array-column `->`/`->>`); **1147–1149** (aggregate casts and
  group-by across an embed). 1143 and 1145 go through `to_jsonb(col)`, so the
  terminal-`->` rule on an actual *json/jsonb* column is still uncased — see
  [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → select*.
- **headers** holds **1550–1584** (35 cases): **1582**/**1583** (the `Vary`
  funnel and its absence on errors) and **1584** (the two-token
  `Preference-Applied` echo that 1553 cannot pin). **headers/vary**
  (1575–1576, 1582–1583) covers the new `references/api/vary_header` docs page;
  the CORS-*preflight* leg is **not** pinned and is an open gap against the
  preflight cases 1702/1703/1742 in the config band.
- **config** holds **1700–1744 (45 cases)**: `client-error-verbosity`
  (1731–1732), `server-reuseport` (1735), `url-use-legacy-target-names` (1736),
  `admin-server-unix-socket` (1737–1738), `db-schemas` rejecting `pg_catalog` /
  `information_schema` (1733–1734), **1739** (`parsing/unknown-key-ignored`),
  **1740–1741** (`coerceBool`), **1742–1743** (the CORS default-preflight and the
  hard-coded `Access-Control-Expose-Headers` list — both **HTTP**, not CLI), and
  **1744** (`db-config = false`).
- **filters** holds **1150–1199** (50 cases) and its primary band is **fully
  allocated** — `spec/filters.yaml` declares `[10600..10799]` as the area's
  closed overflow range. All nine of its newest ids are `filters/embed/*` and
  none needed a fixture delta.
- **ordering** holds **1200–1232** (33 cases); its six newest ids — 1227–1228,
  1229, 1230, 1231–1232 — are **not** v16.0 behavior changes; every one predates
  the pin and had simply never been modelled. They added **no** fixture delta.
- **select/filters/ordering/url_grammar** gained the embed **alias vs. legacy
  target name** rules (1028, 1138–1141, 1188–1190, 1224).
- **auth** grew from 45 to 69 cases; the 19 that did not fit the full 1450–1499
  band went to the 11800–11818 overflow band.

## Case file shapes

Most cases are HTTP request/response (**724**). The **config** area additionally
uses a **CLI** shape (`request.kind: cli`, `request.flag: "--dump-config"`)
asserting on `expect.exit_code`, `expect.dump_contains`,
`expect.dump_reparse_stable`, and `expect.stderr_contains` rather than an HTTP
status — **38** cases, ids **1705–1741 plus 1744**. Note the CLI ids are *not*
one contiguous run: **1742 and 1743 are HTTP** CORS cases sitting inside the
config band, so `1705–1744` is the band, not the CLI set.

The **auth** area uses `request.jwt` to have the runner mint a signed token —
**32** cases do (1460–1464, 1468–1474, 1496–1499, 11800–11808, 11810–11812,
11815–11818); case 11809 is the exception, carrying a literal `Authorization`
header because it needs a token signed with a secret the harness deliberately
does not know.

Any case may carry a `config:` block — **116** do (112 non-empty; 1705, 1719,
1727 and 1743 carry an empty `config: {}`), spread over six areas: config 45,
auth 33, observability 21, select 10, openapi 4, errors 3 (that breakdown counts
the key's *presence*, so it sums to 116). **The count did not
move for a SIXTH consecutive pass**: none of the operators re-sync's 37 new
cases, the rpc re-sync's 3, the mutations re-sync's 17, the representations
re-sync's 8, the content_negotiation re-sync's 6, the openapi re-sync's 6 or the
domain_representations re-sync's 16
declares a `config:` block, because none of those areas is
config-gated — a useful contrast with `select`, whose ten config-carrying cases
all need `db-aggregates-enabled` or `url-use-legacy-target-names` and none of
which the harness honours.

> **The content_negotiation pass is the sharpest illustration that a missing
> `config:` block can itself be the gap.** Its area model states, twice, that the
> plan media types resolve only when `db-plan-enabled` is true
> (`Plan/Negotiate.hs#L74`) — yet cases **1625, 1626, 1627, 1628** and **1643**
> record that requirement in a **`preconditions:` string**, a key the harness
> **never executes**, and no case anywhere pins the **406** that the default
> `db-plan-enabled = false` produces. Upstream asserts it at
> `PlanSpec.hs#L544`. So five cases declare a dependency the harness ignores
> while the behavior that dependency implies is untested. See
> [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → content_negotiation*.

The harness boots a dedicated instance only for the
ids listed in `@variant_case_ids`
(`test/support/conformance_server.ex:58-59`, **18** ids: 1467–1473, 1491, 1493,
1654, 1677, 1678, 1680, 1682, 1703, 1758, 1763, 1764) plus every `kind: cli`
case. On any other HTTP case the `config:` block is **inert** — it documents the
upstream configuration the assertion depends on, but the case still runs against
a shared instance. Mechanically, **60** HTTP cases carry a non-empty `config:`
outside `@variant_case_ids` (re-derived on disk this pass against the harness's
live 18-id list), now out of **724** HTTP cases (762 − 38 CLI); most simply
restate what the shared instance already provides.

> **The openapi pass turned that inertness into a WITHDRAWN case, which is the
> clearest demonstration of the gate this document has.** A case pinning
> `openapi-server-proxy-uri` needs `config: {openapi-server-proxy-uri:
> "https://postgrest.com"}` to be honoured; **1689** is not in the 18-id list, so
> it would have fallen through `url_for/1` to the shared auth instance, read
> `$.host == "127.0.0.1:<port>"` and failed for a reason unrelated to the
> behavior. The pass authored it, saw the red, and **withdrew it rather than ship
> a broken case or weaken the assertion** — recording in `openapi.yaml`'s `gaps:`
> exactly what the harness owner must add and what to restore afterwards. **This
> is the one deliverable of that pass a `spec/`-only edit could not complete**,
> and it is the model for how a harness gate should be handed over. **The mutations band adds a dependency of a
different kind**: it declares no `config:` at all, yet ten of its seventeen new
cases rely on the shared instance's `db_tx_end: :rollback` to contain writes
through un-isolated view mirrors — an *undeclared* dependency, which is worse
than an ignored one because nothing mechanical can surface it.

> **The domain_representations band inherits that same undeclared dependency for
> FOURTEEN cases, and it is the first pass to write the dependency down.** Cases
> **1823–1836** POST and PATCH against `datarep_todos` and the auto-updatable
> `datarep_todos_computed`, neither of which the loader isolates as a real table;
> they are contained solely by `db_tx_end: :rollback`
> (`test/support/conformance_server.ex`) plus `Bier.Mutation.finish_tx/3`. What
> is new is that `domain_representations.yaml`'s retired `mutation_isolation`
> gap now **states the mechanism explicitly**, naming both files and the upstream
> equivalent (`configDbTxRollbackAll = True`, `SpecHelper.hs#L176`). That is the
> nearest thing in the tree to the write-containment declaration
> [`../COVERAGE.md`](../COVERAGE.md) → follow-up 27 asks for — recorded in a gap
> entry rather than in the case shape, which is where it belongs long-term.
The instances where the declared config *diverges* from the shared instance, and
the assertion therefore depends on it, are case **1742**, the ten select cases
**1129–1133, 1139, 1140, 1147–1149**, the three errors cases **1517, 1518, 1522**
(which `spec/errors.yaml`'s own `harness_gate:` key names explicitly), and the
three observability cases **1765, 1766, 1767** (which declare `log-level:
warn|info|crit` against a shared instance pinned to `log_level: :error`; their
assertions are log-level-independent statuses, so they still hold — see
`spec/observability.yaml` → gaps). See
[`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → config*.

`preconditions:` is parsed but **never executed** by the harness — treat it as
declarative documentation, never as setup a case may depend on. It is present on
**761** of the 762 cases (case **1330** is still the only omission, which the
schema allows), and **42** of those carry a *non-empty* list — **25 of the 42 in
the mutations area alone**, which makes it by far the heaviest user of a key that
does nothing. Full non-empty distribution, re-derived at the 762-case state and
**unchanged**:
mutations **25**, content_negotiation **11**, pagination **4**,
url_grammar **1**, representations **1**. All sixteen new domain_representations
cases correctly carry `preconditions: []`, as all six openapi, all six
content_negotiation, all 17
mutations and all 8 representations cases did before them — a convention five
consecutive passes have now followed and nobody has written down.

> **The openapi pass is the first to REMOVE non-empty preconditions, and it
> removed the only two that were demonstrably wrong.** The area carried 2; it now
> carries **0**, which is the whole of the tree-wide 44 → 42. Both were also
> incorrect had they ever run: case **1654**'s `COMMENT ON SCHEMA test IS NULL`
> would have broken case **1656** (which asserts that very comment as the
> document title), and case **1672**'s `CREATE FUNCTION` omitted the
> `DEFAULT '{}'` that 1672's own `required: false` assertion depends on. **Two
> inert-but-wrong statements survived an entire prior re-sync of this area
> unnoticed** — which is the sharpest available argument that an unexecuted key
> is worse than no key. Recorded in `openapi.yaml`'s `gaps:` as an
> `operator_action:` entry and in [`../COVERAGE.md`](../COVERAGE.md) →
> follow-up 25.

**Two areas show the cost, and they show it differently.** In *pagination*,
cases **1272, 1274 and 1275** declare `preconditions: ["ANALYZE …"]` for
planner-estimate expectations and pass only because `mix bier.fixtures.load`
happens to run a database-wide `ANALYZE` afterwards; `spec/pagination.yaml`
records this for the harness owner rather than working around it. In
*content_negotiation*, **eleven** cases carry non-empty lists and five of them
(**1625–1628**, **1643**) use the key to state the `db-plan-enabled = true`
requirement — where pagination's inert preconditions happen to be satisfied,
these five leave a documented gate with **no case pinning the ungated 406**.
An inert declaration is not coverage.

**3** cases assert `expect.status_text` (**1508, 1510, 1511**) and are tagged
`:pending` / excluded by `test/conformance/conformance_test.exs`, because `Req`
does not expose the HTTP reason phrase. That is the harness's only remaining
deferral; `case.schema.json` itself has no `pending` field. (Earlier revisions of
this file claimed 6 such cases, listing 1509, 1513 and 1514 as well — those three
only *mention* `status_text` in `notes:` or in an expected `hint:` string and
carry no `expect.status_text` key, so they run normally. Re-verified at the
**762**-case state: still exactly three.)

**13** cases use the HTTP `HEAD` method (1020, 1272, 1274, 1275, 1277, 1284,
1425, 1681, 1756, 1760, 1761, 1762, 1771) and **every one expects a 2xx** —
re-derived mechanically at the 762-case state. No case in the tree issues a HEAD
request that errors, which is the tree's only *request-shape* blind spot; see
[`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → errors*. **The count has now
not moved in nine re-syncs while the tree grew by 86 cases.** This pass is the
first with a structural excuse: fourteen of its sixteen new cases are mutations,
and a HEAD on a mutation is not a shape upstream asserts anywhere. Full method
distribution at **762**: GET **511**, POST **114**, CLI **38**, PATCH **35**,
DELETE **21**, PUT **18**, HEAD **13**, OPTIONS **12** (sums to 762). **PATCH
27 → 35 is the largest single-pass growth that method has had.**

## Looking up a case

```sh
# all cases in an area
grep -l '^feature: domain_representations/' spec/conformance/cases/*.yaml

# the source citation for a case
grep '^source:' spec/conformance/cases/1200_order_by_column_asc.yaml

# list ids in numeric order — REQUIRED: the four 5-digit bands sort wrong
# otherwise (operators 10200-10236 lands next to 1020*, mutations
# 11400-11415 next to 1140*, auth 11800-11818 next to 1180*, and
# content_negotiation 12400-12401 next to 1240* — an empty slice, so it
# interleaves with nothing and is the easiest of the four to overlook)
ls spec/conformance/cases/ | sort -n

# every case in an overflow band, by area
ls spec/conformance/cases/ | sort -n | grep -E '^(102|114|118|124)[0-9]{2}_'
```
