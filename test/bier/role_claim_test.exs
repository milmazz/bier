defmodule Bier.RoleClaimTest do
  # jwt-role-claim-key (issue #49, conformance case 1711): the JSPath grammar,
  # canonical dump form, and claim extraction mirror PostgREST v14.12's
  # PostgREST.Config.JSPath (pRoleClaimKey / dumpJSPath) and Auth walk.
  use ExUnit.Case, async: true

  alias Bier.JWT.RoleClaim

  describe "parse/1 accepts PostgREST's grammar" do
    test "default path" do
      assert {:ok, [{:key, "role"}]} = RoleClaim.parse(".role")
    end

    test "bare keys allow alphanumerics, underscore, $ and @" do
      assert {:ok, [{:key, "a1_$@"}]} = RoleClaim.parse(".a1_$@")
    end

    test "nested keys and array indexes" do
      assert {:ok, [{:key, "realm"}, {:key, "roles"}, {:idx, 0}]} =
               RoleClaim.parse(".realm.roles[0]")
    end

    test "quoted keys admit dashes and spaces, and may be empty" do
      assert {:ok, [{:key, "my-role key"}]} = RoleClaim.parse(~s(."my-role key"))
      assert {:ok, [{:key, ""}]} = RoleClaim.parse(~s(.""))
    end

    test "a path may start with an index" do
      assert {:ok, [{:idx, 2}, {:key, "role"}]} = RoleClaim.parse("[2].role")
    end

    test "filter expressions, only in final position" do
      assert {:ok, [{:key, "roles"}, {:filter, :eq, "admin"}]} =
               RoleClaim.parse(~s|.roles[?(@ == "admin")]|)

      assert {:ok, [{:key, "r"}, {:filter, :not_eq, "x"}]} = RoleClaim.parse(~s|.r[?(@ != "x")]|)

      assert {:ok, [{:key, "r"}, {:filter, :starts_with, "x"}]} =
               RoleClaim.parse(~s|.r[?(@ ^== "x")]|)

      assert {:ok, [{:key, "r"}, {:filter, :ends_with, "x"}]} =
               RoleClaim.parse(~s|.r[?(@ ==^ "x")]|)

      assert {:ok, [{:key, "r"}, {:filter, :contains, "x"}]} =
               RoleClaim.parse(~s|.r[?(@ *== "x")]|)

      # Spaces around the operator are optional (parsec P.spaces), and other
      # ASCII whitespace is accepted like isSpace.
      assert {:ok, [{:key, "r"}, {:filter, :eq, "x"}]} = RoleClaim.parse(~s|.r[?(@=="x")]|)
      assert {:ok, [{:key, "r"}, {:filter, :eq, "x"}]} = RoleClaim.parse(".r[?(@\f==\v\"x\")]")
    end
  end

  describe "parse/1 rejects what PostgREST rejects, with the pinned message" do
    test "missing leading dot (case 1711's value)" do
      assert {:error, "failed to parse role-claim-key value (role.other)"} =
               RoleClaim.parse("role.other")
    end

    test "empty input, bad index, trailing garbage, non-final filter" do
      for bad <- [
            "",
            ".",
            ".a[",
            ".a[b]",
            ".a]",
            ~s|.a[?(@ == "x")].b|,
            ".a b",
            ~s(."unterminated)
          ] do
        assert {:error, "failed to parse role-claim-key value (" <> _} = RoleClaim.parse(bad),
               "expected rejection of #{inspect(bad)}"
      end
    end
  end

  describe "dump/1 renders PostgREST's canonical form" do
    test "keys are always quoted (1705/1707 dump shape)" do
      {:ok, path} = RoleClaim.parse(".role")
      assert RoleClaim.dump(path) == ~s(."role")

      {:ok, path} = RoleClaim.parse(".aliased")
      assert RoleClaim.dump(path) == ~s(."aliased")
    end

    test "indexes and filters round-trip" do
      {:ok, path} = RoleClaim.parse(~s(.realm.roles[0]))
      assert RoleClaim.dump(path) == ~s(."realm"."roles"[0])

      {:ok, path} = RoleClaim.parse(~s|.roles[?(@=="admin")]|)
      assert RoleClaim.dump(path) == ~s|."roles"[?(@ == "admin")]|
    end
  end

  describe "extract/2" do
    test "walks nested keys and indexes; only non-empty strings are roles" do
      claims = %{"realm" => %{"roles" => ["writer", "admin"]}}
      {:ok, path} = RoleClaim.parse(".realm.roles[1]")
      assert RoleClaim.extract(claims, path) == "admin"

      {:ok, path} = RoleClaim.parse(".realm.roles[9]")
      assert RoleClaim.extract(claims, path) == nil

      {:ok, path} = RoleClaim.parse(".realm")
      assert RoleClaim.extract(claims, path) == nil

      {:ok, path} = RoleClaim.parse(".missing")
      assert RoleClaim.extract(claims, path) == nil

      {:ok, path} = RoleClaim.parse(".role")
      assert RoleClaim.extract(%{"role" => ""}, path) == nil
      assert RoleClaim.extract(%{"role" => 42}, path) == nil
    end

    test "filters select the first matching string element of an array" do
      claims = %{"roles" => ["one", "two", "twenty"]}

      checks = [
        {~s|.roles[?(@ == "two")]|, "two"},
        {~s|.roles[?(@ != "one")]|, "two"},
        {~s|.roles[?(@ ^== "tw")]|, "two"},
        {~s|.roles[?(@ ==^ "enty")]|, "twenty"},
        {~s|.roles[?(@ *== "went")]|, "twenty"},
        {~s|.roles[?(@ == "absent")]|, nil}
      ]

      for {expr, expected} <- checks do
        {:ok, path} = RoleClaim.parse(expr)
        assert RoleClaim.extract(claims, path) == expected, "path #{expr}"
      end

      # A filter over a non-array yields no role.
      {:ok, path} = RoleClaim.parse(~s|.roles[?(@ == "x")]|)
      assert RoleClaim.extract(%{"roles" => "not-a-list"}, path) == nil
    end
  end
end
