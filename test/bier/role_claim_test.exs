defmodule Bier.RoleClaimTest do
  # jwt-role-claim-key (issue #49, conformance case 1711): the JSON Path
  # grammar, canonical dump form and claim extraction mirror PostgREST v16.0's
  # PostgREST.Config.JSPath, which delegates to `aeson-jsonpath` (RFC 9535).
  # v16.0 retired the v14.12 leading-dot JSPath DSL wholesale (issue #93), so
  # every RFC 9535 expression starts with the root identifier `$`; v16.2
  # (PostgREST#5171) accepts the old DSL again as a deprecated fallback, covered
  # at the end of this file.
  use ExUnit.Case, async: true

  alias Bier.JWT.RoleClaim

  describe "parse/1 accepts PostgREST's grammar" do
    test "default path" do
      assert {:ok, [{:name, :dot, "role"}]} = RoleClaim.parse(~S|$.role|)
    end

    test "the dotted shorthand takes letters, digits and underscore" do
      assert {:ok, [{:name, :dot, "a1_b"}]} = RoleClaim.parse(~S|$.a1_b|)
    end

    test "nested names and array indexes, negative counting from the end" do
      assert {:ok, [{:name, :dot, "realm"}, {:name, :dot, "roles"}, {:index, 0}]} =
               RoleClaim.parse(~S|$.realm.roles[0]|)

      assert {:ok, [{:name, :dot, "realm"}, {:name, :dot, "roles"}, {:index, -1}]} =
               RoleClaim.parse(~S|$.realm.roles[-1]|)
    end

    test "a name with anything but letters/digits/underscore needs the bracket selector" do
      # The v14.12 spelling `.roles."write-role"` is gone; v16 wants
      # `$.roles["write-role"]`. Both quote styles are RFC 9535 name selectors.
      assert {:ok, [{:name, :dot, "roles"}, {:name, :bracket, "write-role"}]} =
               RoleClaim.parse(~S|$.roles["write-role"]|)

      assert {:ok, [{:name, :bracket, "write-role"}]} = RoleClaim.parse(~S|$['write-role']|)
    end

    test "filter selectors, parenthesized or bare" do
      assert {:ok, [{:name, :dot, "roles"}, {:filter, {:paren, comparison}}]} =
               RoleClaim.parse(~S|$.roles[?(@ == "admin")]|)

      assert {:comparison, {:query, :current, []}, :eq, {:lit, "admin"}} = comparison

      assert {:ok, [{:name, :dot, "roles"}, {:filter, ^comparison}]} =
               RoleClaim.parse(~S|$.roles[?@ == "admin"]|)
    end

    test "search() replaces the retired ^== / ==^ / *== operators" do
      # v14.12's `.roles[?(@ ^== "postgrest_test_")]` migrates to the RFC 9535
      # search() function over a regex (PostgREST #4984).
      assert {:ok, [{:name, :dot, "roles"}, {:filter, filter}]} =
               RoleClaim.parse(~S|$.roles[?search(@, "^postgrest_test_")]|)

      assert {:search, {:query, :current, []}, {:lit, "^postgrest_test_"}} = filter
    end

    test "the bare root identifier is a valid query selecting the claims object" do
      # Syntactically fine (RFC 9535 root identifier, no segments); it just
      # never yields a role, since the claims object is not a string.
      assert {:ok, []} = RoleClaim.parse(~S|$|)
      assert RoleClaim.extract(%{"role" => "x"}, []) == nil
    end

    test "a filter comparable may be a singular query with a bracketed name" do
      assert {:ok, [{:name, :dot, "a"}, {:filter, {:paren, comparison}}]} =
               RoleClaim.parse(~S|$.a[?(@["x-y"] == "z")]|)

      assert {:comparison, {:query, :current, [{:name, :bracket, "x-y"}]}, :eq, {:lit, "z"}} =
               comparison
    end
  end

  describe "parse/1 rejects what PostgREST rejects, with the pinned message" do
    test "a value neither RFC 9535 nor the deprecated DSL accepts (case 1711's value)" do
      assert {:error, "failed to parse role-claim-key value (@@.role.other)"} =
               RoleClaim.parse("@@.role.other")

      # No leading `.`: invalid in both grammars (upstream's
      # deprecatedinvalidroleclaimkeys).
      assert {:error, "failed to parse role-claim-key value (role.other)"} =
               RoleClaim.parse("role.other")
    end

    test "empty input, bad index, trailing garbage, unterminated quoting" do
      for bad <- [
            "",
            "$.",
            "$.a[",
            "$.a[b]",
            "$.a]",
            "$.a b",
            # A quoted name is a BRACKET selector; `."x"` is not RFC 9535.
            ~S|$.""|,
            ~S|$["unterminated|
          ] do
        assert {:error, "failed to parse role-claim-key value (" <> _} = RoleClaim.parse(bad),
               "expected rejection of #{inspect(bad)}"
      end
    end

    test "the unmodelled RFC 9535 constructs are rejected, but as UNSUPPORTED (#99)" do
      # Descendant segments, wildcards, slices, comma multi-selectors and the
      # logical combinators parse upstream but are outside Bier's hand-written
      # subset, and a rejection aborts startup rather than degrading. They are
      # well-formed RFC 9535, so the message names the construct instead of
      # claiming the operator's syntax is wrong — and it must NOT reuse the
      # malformed wording case 1711 pins.
      for {bad, construct} <- [
            {~S|$..role|, "descendant segment"},
            {~S|$..*|, "descendant segment"},
            {~S|$.roles[*]|, "wildcard selector"},
            {~S|$.*|, "wildcard selector"},
            {~S|$.roles[0:2]|, "array slice"},
            {~S|$.roles[:2]|, "array slice"},
            {~S|$.roles[0,1]|, "multi-selector"},
            {~S{$.roles[?(@ == "a") && (@ == "b")]}, "logical combinator"},
            {~S{$.roles[?@ == "a" || @ == "b"]}, "logical combinator"},
            {~S{$.roles[?!(@ == "a")]}, "logical combinator"}
          ] do
        assert {:error, message} = RoleClaim.parse(bad), "expected rejection of #{inspect(bad)}"

        assert message =~ "unsupported role-claim-key construct (#{construct})",
               "wrong construct named for #{inspect(bad)}: #{message}"

        assert message =~ bad
        refute message =~ "failed to parse role-claim-key value"
      end
    end

    test "a genuinely malformed value keeps case 1711's message verbatim" do
      assert {:error, "failed to parse role-claim-key value (@@.role.other)"} =
               RoleClaim.parse("@@.role.other")
    end
  end

  describe "parse/1 skips RFC 9535 whitespace between segments (#102)" do
    # `segments = *(S segment)`, so `$ .a` and `$.a [0]` are legal queries that
    # aeson-jsonpath accepts; only `segments/2` was missing the `S` skip that
    # `singular_segments/3` already had.
    test "whitespace before and between segments" do
      assert {:ok, [{:name, :dot, "a"}]} = RoleClaim.parse(~S|$ .a|)
      assert {:ok, [{:name, :dot, "a"}, {:index, 0}]} = RoleClaim.parse(~S|$.a [0]|)
      assert {:ok, [{:name, :dot, "a"}, {:name, :dot, "b"}]} = RoleClaim.parse("$.a\t.b")
      assert {:ok, [{:name, :dot, "role"}]} = RoleClaim.parse(~S|$.role |)
    end

    test "whitespace is not a substitute for a segment separator" do
      assert {:error, _} = RoleClaim.parse(~S|$.a b|)
    end
  end

  describe "dump/1 renders the canonical RFC 9535 form" do
    test "the dotted shorthand stays dotted (1705/1707 dump shape)" do
      # Case 1705 pins `jwt-role-claim-key = "$$.role"` and 1707 `"$$.aliased"`;
      # the `$` -> `$$` half is the config layer's escaping, not dump/1's.
      assert dumped(~S|$.role|) == ~S|$.role|
      assert dumped(~S|$.aliased|) == ~S|$.aliased|
    end

    test "bracketed names and string literals render single-quoted" do
      assert dumped(~S|$.roles["write-role"]|) == ~S|$.roles['write-role']|
      assert dumped(~S|$.realm.roles[0]|) == ~S|$.realm.roles[0]|
      assert dumped(~S|$.roles[?(@ == "admin")]|) == ~S|$.roles[?(@ == 'admin')]|
      assert dumped(~S|$.roles[?search(@, "^pg_")]|) == ~S|$.roles[?search(@, '^pg_')]|
    end

    test "a filter keeps the parenthesization it was written with" do
      assert dumped(~S|$.roles[?(@ == "a")]|) == ~S|$.roles[?(@ == 'a')]|
      assert dumped(~S|$.roles[?@ == "a"]|) == ~S|$.roles[?@ == 'a']|
    end

    test "quoting is escaped so the dump re-parses (case 1726's rule)" do
      # Upstream's dumpQuery is write-only and emits text its own parser
      # rejects. Bier re-reads its own dump (Bier.CLI.Config canonicalizes
      # through dump/1 and hands the result to Bier.start_link/1), so the
      # enclosing quote is escaped, and a bare `"` is escaped to its \\u form
      # because it would otherwise not survive dumpJSPath's `"` -> `\"` rewrite
      # and the config reader's undo of it.
      assert dumped(~S|$["it's"]|) == ~S|$['it\'s']|
      assert dumped(~S|$.a[?(@ == "it's")]|) == ~S|$.a[?(@ == 'it\'s')]|

      # Spelled with a real escape so the expectation is unambiguous: the dump
      # holds the six literal characters ", not a `"`.
      assert dumped(~S|$['a"b']|) == "$['a" <> "\\u0022" <> "b']"

      # The property that matters: every dump re-parses to the same path.
      for input <- [
            ~S|$["it's"]|,
            ~S|$['a"b']|,
            ~S|$.a[?(@ == "it's")]|,
            ~S|$.a[?(@["x-y"] == "z")]|
          ] do
        {:ok, path} = RoleClaim.parse(input)
        assert {:ok, ^path} = RoleClaim.parse(RoleClaim.dump(path)), "round trip #{input}"
      end
    end

    test "a singular-query name is bracketed unless it is a bare shorthand" do
      # dumpQuery always dots it, which mangles `@["x-y"]` into `@.x-y`.
      assert dumped(~S|$.a[?(@["x-y"] == "z")]|) == ~S|$.a[?(@['x-y'] == 'z')]|
      assert dumped(~S|$.a[?(@.b == "z")]|) == ~S|$.a[?(@.b == 'z')]|
    end
  end

  describe "extract/2" do
    test "walks names and indexes; only non-empty strings are roles" do
      claims = %{"realm" => %{"roles" => ["writer", "admin"]}}

      assert extracted(claims, ~S|$.realm.roles[1]|) == "admin"
      assert extracted(claims, ~S|$.realm.roles[-1]|) == "admin"
      assert extracted(claims, ~S|$.realm.roles[9]|) == nil
      assert extracted(claims, ~S|$.realm|) == nil
      assert extracted(claims, ~S|$.missing|) == nil

      assert extracted(%{"role" => ""}, ~S|$.role|) == nil
      assert extracted(%{"role" => 42}, ~S|$.role|) == nil
    end

    test "filters select the first matching string element of an array" do
      claims = %{"roles" => ["one", "two", "twenty"]}

      checks = [
        {~S|$.roles[?(@ == "two")]|, "two"},
        {~S|$.roles[?(@ != "one")]|, "two"},
        {~S|$.roles[?search(@, "^tw")]|, "two"},
        {~S|$.roles[?search(@, "enty$")]|, "twenty"},
        {~S|$.roles[?search(@, "went")]|, "twenty"},
        {~S|$.roles[?(@ == "absent")]|, nil}
      ]

      for {expr, expected} <- checks do
        assert extracted(claims, expr) == expected, "path #{expr}"
      end

      # A filter over a non-array, non-object yields no role.
      assert extracted(%{"roles" => "not-a-list"}, ~S|$.roles[?(@ == "x")]|) == nil
    end

    test "a filter over an object selects members in ascending name order" do
      # RFC 9535 leaves object member order implementation-defined but requires
      # one fixed choice; plain Elixir map iteration is unspecified and changes
      # with map size, which would resolve identical claims to different roles
      # across boots. Sorting by member name is what Bier pins.
      claims = %{"roles" => %{"b" => "beta", "a" => "alpha", "c" => "gamma"}}
      assert extracted(claims, ~S|$.roles[?search(@, "a")]|) == "alpha"

      big = Map.new(1..40, fn i -> {"k#{i}", "role#{i}"} end)
      assert extracted(%{"roles" => big}, ~S|$.roles[?search(@, "^role")]|) == "role1"
    end
  end

  describe "the deprecated JSPath fallback (PostgREST v16.2, #5171)" do
    test "parses keys, quoted keys, indexes and a trailing filter" do
      assert {:ok, {:deprecated, [{:key, "postgrest"}, {:key, "a_role"}]}} =
               RoleClaim.parse(".postgrest.a_role")

      assert {:ok, {:deprecated, [{:key, "https://x.io/roles"}, {:index, 1}]}} =
               RoleClaim.parse(~S|."https://x.io/roles"[1]|)

      assert {:ok, {:deprecated, [{:key, "a$b@c_1"}]}} = RoleClaim.parse(".a$b@c_1")

      for {op_text, op} <- [
            {"==", :eq},
            {"!=", :ne},
            {"^==", :starts_with},
            {"==^", :ends_with},
            {"*==", :contains}
          ] do
        assert {:ok, {:deprecated, [{:key, "roles"}, {:filter, ^op, "r"}]}} =
                 RoleClaim.parse(~s|.roles[?(@ #{op_text} "r")]|)
      end

      # Whitespace around the operator is optional.
      assert {:ok, {:deprecated, [{:key, "roles"}, {:filter, :eq, "r"}]}} =
               RoleClaim.parse(~S|.roles[?(@=="r")]|)
    end

    test "rejects what the deprecated grammar rejects, with case 1711's message" do
      for bad <- [
            ".",
            ".a-b",
            ".a[",
            ".a[-1]",
            ~S|.a["x"]|,
            ~S|."unterminated|,
            ~S|.roles[?(@ == "a")].next|,
            ~S|.roles[?(@ < "a")]|,
            ~S|.roles[?(@ == 'a')]|
          ] do
        assert {:error, "failed to parse role-claim-key value (" <> _} = RoleClaim.parse(bad),
               "expected rejection of #{inspect(bad)}"
      end
    end

    test "an RFC 9535 value never falls back, even when unsupported" do
      assert {:ok, [{:name, :dot, "role"}]} = RoleClaim.parse("$.role")
      assert {:error, "unsupported role-claim-key construct" <> _} = RoleClaim.parse("$..role")
    end

    test "dumps every key quoted and the filter as written" do
      assert dumped(".roles.user_role") == ~S|."roles"."user_role"|
      assert dumped(~S|.roles[?(@ ^== "role1")]|) == ~S|."roles"[?(@ ^== "role1")]|
      assert dumped(~S|.a[0][?(@=="x")]|) == ~S|."a"[0][?(@ == "x")]|

      # The dump re-parses to the same path (the --dump-config round trip).
      for input <- [".roles.user_role", ~S|."a b"[2][?(@ *== "x y")]|] do
        {:ok, parsed} = RoleClaim.parse(input)
        assert RoleClaim.parse(RoleClaim.dump(parsed)) == {:ok, parsed}
      end
    end

    test "extracts the role like evaluateDeprecatedJSPath" do
      roles = %{"realm_access" => %{"roles" => ["other", "postgrest_test_author"]}}

      for {expr, expected} <- [
            {~S|.realm_access.roles[?(@ == "other")]|, "other"},
            {~S|.realm_access.roles[?(@ != "other")]|, "postgrest_test_author"},
            {~S|.realm_access.roles[?(@ ^== "postgrest_te")]|, "postgrest_test_author"},
            {~S|.realm_access.roles[?(@ ==^ "author")]|, "postgrest_test_author"},
            {~S|.realm_access.roles[?(@ *== "test")]|, "postgrest_test_author"},
            {~S|.realm_access.roles[1]|, "postgrest_test_author"},
            {~S|.realm_access.roles[2]|, nil},
            {~S|.realm_access.missing|, nil}
          ] do
        assert extracted(roles, expr) == expected, "path #{expr}"
      end

      assert extracted(%{"postgrest" => %{"a_role" => "x"}}, ".postgrest.a_role") == "x"
      assert extracted(%{"https://x.io/r" => "y"}, ~S|."https://x.io/r"|) == "y"

      # A filter compares strings only: an object element never matches
      # (case 11821), and a filter over a non-array selects nothing.
      objects = %{"roles" => [%{"obj_key" => "obj_value"}]}
      assert extracted(objects, ~S|.roles[?(@ == "string")]|) == nil
      assert extracted(%{"roles" => "string"}, ~S|.roles[?(@ == "string")]|) == nil
    end

    test "only a deprecated path carries the deprecation warning" do
      {:ok, parsed} = RoleClaim.parse(".roles.user_role")

      assert [
               "WARNING: The config `jwt-role-claim-key=.\"roles\".\"user_role\"` is using the deprecated JSPath syntax.",
               "Update `jwt-role-claim-key=.\"roles\".\"user_role\"` to the new JSONPath syntax" <>
                 _
             ] = RoleClaim.deprecation_warning(parsed)

      {:ok, parsed} = RoleClaim.parse("$.role")
      assert RoleClaim.deprecation_warning(parsed) == nil
    end
  end

  defp dumped(input) do
    {:ok, path} = RoleClaim.parse(input)
    RoleClaim.dump(path)
  end

  defp extracted(claims, input) do
    {:ok, path} = RoleClaim.parse(input)
    RoleClaim.extract(claims, path)
  end
end
