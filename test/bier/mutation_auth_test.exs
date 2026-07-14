defmodule Bier.MutationAuthTest do
  @moduledoc """
  Table mutations (`POST`/`PATCH`/`PUT`/`DELETE`) must run inside the same
  per-request auth context (role switch, `request.*` GUCs, `db-pre-request`) as
  reads (`Bier.QueryExecutor`) and RPC (`Bier.Rpc`) — issue #73. Boots a
  dedicated auth-configured instance (`Bier.ConformanceServer.auth_opts/0`,
  exposing only the `test` schema so no `Accept-Profile` header is needed) and
  exercises `test.authors_only`:

      CREATE TABLE test.authors_only (
        owner  text NOT NULL DEFAULT current_setting('request.jwt.claims', true)::json->>'id',
        secret text NOT NULL,
        ...
      );

  Only `postgrest_test_author` has grants on the table (`GRANT ALL ... TO
  postgrest_test_author`); `postgrest_test_anonymous` has none. `auth_opts/0`
  carries `db_tx_end: :rollback`, so every insert is rolled back after the
  response is computed — nothing persists, so no cleanup is needed.

  Two complementary proofs:

    * a GUC-based positive case — an authenticated author's JWT `id` claim
      must reach the write's `DEFAULT` expression (proves the role/GUC
      context, not just a hardcoded value, is threaded through: two different
      claims produce two different owners);
    * a privilege-based negative case — an anonymous request must be denied
      (401) rather than silently succeeding as the connecting superuser, which
      is the actual security hole #73 describes.

  Both assertions fail against the pre-fix `Bier.Mutation.run/4` (no auth
  context at all): the GUC case gets a NOT NULL constraint violation on
  `owner` (the DEFAULT reads an unset GUC — no role switch ran to set it), and
  the anonymous case (which supplies `owner` explicitly, bypassing the
  DEFAULT/GUC entirely) wrongly succeeds with 201 — because with no role
  switch the write runs as the connecting superuser instead of the
  unprivileged anon role.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  @secret "reallyreallyreallyreallyverysafe"

  setup_all do
    port = TestPorts.free_port()
    name = :"mutation_auth_#{System.unique_integer([:positive])}"

    opts =
      Bier.ConformanceServer.auth_opts()
      |> Keyword.merge(name: name, router: [port: port, scheme: :http], db_schemas: ["test"])

    {:ok, pid} = Bier.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)
    TestPorts.wait_until_listening(port)
    %{base: "http://localhost:#{port}"}
  end

  defp jwt(claims) do
    {_meta, token} =
      @secret
      |> JOSE.JWK.from_oct()
      |> JOSE.JWT.sign(%{"alg" => "HS256"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  defp post!(base, path, headers, body) do
    Req.request!(
      method: :post,
      url: base <> path,
      headers: headers,
      body: body,
      retry: false,
      decode_body: false
    )
  end

  defp decode!(body), do: Bier.json_library().decode!(body)

  describe "INSERT applies the auth context (GUC-based, deterministic)" do
    test "the JWT's id claim flows through to the DEFAULT-derived column", %{base: base} do
      token = jwt(%{"role" => "postgrest_test_author", "id" => "author-42"})

      resp =
        post!(
          base,
          "/authors_only",
          [
            {"authorization", "Bearer " <> token},
            {"content-type", "application/json"},
            {"prefer", "return=representation"}
          ],
          ~s({"secret": "s3kr3t"})
        )

      assert resp.status == 201
      assert [%{"owner" => "author-42", "secret" => "s3kr3t"}] = decode!(resp.body)
    end

    test "a different id claim produces a different owner (rules out a hardcoded value)", %{
      base: base
    } do
      token = jwt(%{"role" => "postgrest_test_author", "id" => "author-99"})

      resp =
        post!(
          base,
          "/authors_only",
          [
            {"authorization", "Bearer " <> token},
            {"content-type", "application/json"},
            {"prefer", "return=representation"}
          ],
          ~s({"secret": "other-secret"})
        )

      assert resp.status == 201
      assert [%{"owner" => "author-99", "secret" => "other-secret"}] = decode!(resp.body)
    end
  end

  describe "INSERT applies the auth context (privilege-based)" do
    test "an anonymous insert is denied (401), not silently run as the superuser", %{base: base} do
      # `owner` is supplied explicitly so the DEFAULT (and its GUC read) never
      # runs — this isolates the privilege check from the GUC-based cases
      # above. Pre-fix, no role switch happens at all, so the write executes
      # as the connecting superuser and wrongly succeeds (201); post-fix, the
      # anon role (no grants on test.authors_only) gets 42501 -> 401.
      resp =
        post!(
          base,
          "/authors_only",
          [{"content-type", "application/json"}, {"prefer", "return=representation"}],
          ~s({"owner": "nobody", "secret": "anon-secret"})
        )

      assert resp.status == 401
      assert ["Bearer"] = resp.headers["www-authenticate"]
      assert %{"code" => "42501"} = decode!(resp.body)
    end
  end
end
