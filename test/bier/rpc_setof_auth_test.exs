defmodule Bier.RpcSetofAuthTest do
  @moduledoc """
  `/rpc/<fn>` where the routine returns `SETOF <exposed relation>` must run
  inside the same per-request auth context (role switch, `request.*` GUCs,
  `db-pre-request`) as every other execution path — issue #108. That branch
  (`Bier.Rpc.run_setof_rel/8` -> `Bier.QueryExecutor.run_function/6`) used to
  issue a bare `Postgrex.query/3` on the pool, so the statement ran as the
  connecting role with no role switch, no claims GUC and no pre-request hook.

  The conformance suite cannot see this: `Bier.ConformanceServer` connects as
  the OS superuser, which inherits every privilege whether or not `SET LOCAL
  ROLE` ran, and the GUC-reading cases all go through scalar/composite RPCs
  (the path that already applied auth). Hence this Bier-side regression test,
  which boots its own auth-configured instance and leans on the *unprivileged*
  fixture roles.

  Four complementary proofs, all against `test`-schema fixtures:

    * privilege-based negative — an anonymous `SETOF test.projects` call must
      be denied (`postgrest_test_anonymous` has no `SELECT` on `test.projects`)
      instead of silently succeeding as the connecting superuser;
    * role-identity — the same call under an authenticated
      `postgrest_test_author` token must fail as *that* role (403, no
      `WWW-Authenticate`) rather than as the assumed anon role (401), proving
      the JWT's role — not merely "some role" — reaches the statement;
    * GUC + pre-request — with `db-pre-request: test.switch_role` (which reads
      `request.jwt.claims->>'id'`), an `id=3` token must surface the routine's
      `RAISE EXCEPTION` as P0001/400, proving both the claims GUC and the hook
      ran (mirrors conformance case 1477, which exercises a scalar RPC);
    * positive — an anonymous call the anon role *is* granted
      (`SETOF test.items`) still succeeds, so the new context does not break
      legitimate access.

  All four fail pre-fix: the first three return 200 with data (no auth context
  at all), and only the last one passes.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  @secret "reallyreallyreallyreallyverysafe"

  setup_all do
    port = TestPorts.free_port()
    name = :"rpc_setof_auth_#{System.unique_integer([:positive])}"

    opts =
      Bier.ConformanceServer.auth_opts()
      |> Keyword.merge(
        name: name,
        router: [port: port, scheme: :http],
        db_schemas: ["test"],
        db_pre_request: "test.switch_role"
      )

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

  defp get!(base, path, headers \\ []) do
    Req.request!(
      method: :get,
      url: base <> path,
      headers: [{"accept", "application/json"} | headers],
      retry: false,
      decode_body: false
    )
  end

  defp decode!(body), do: Bier.json_library().decode!(body)

  describe "SETOF-relation RPC applies the auth context (privilege-based)" do
    test "an anonymous call is denied (401), not silently run as the superuser", %{base: base} do
      resp = get!(base, "/rpc/getallprojects")

      assert resp.status == 401
      assert ["Bearer"] = resp.headers["www-authenticate"]
      assert %{"code" => "42501"} = decode!(resp.body)
    end

    test "an authenticated call runs as the JWT's role (403, not 401)", %{base: base} do
      token = jwt(%{"role" => "postgrest_test_author"})

      resp = get!(base, "/rpc/getallprojects", [{"authorization", "Bearer " <> token}])

      assert resp.status == 403
      refute Map.has_key?(resp.headers, "www-authenticate")
      assert %{"code" => "42501"} = decode!(resp.body)
    end
  end

  describe "SETOF-relation RPC applies the auth context (GUC + pre-request)" do
    test "db-pre-request runs and sees request.jwt.claims", %{base: base} do
      token = jwt(%{"id" => 3})

      resp = get!(base, "/rpc/getallprojects", [{"authorization", "Bearer " <> token}])

      assert resp.status == 400

      assert %{
               "code" => "P0001",
               "message" => "Disabled ID --> 3",
               "hint" => "Please contact administrator",
               "details" => nil
             } = decode!(resp.body)
    end
  end

  describe "SETOF-relation RPC under the auth context still serves granted reads" do
    test "an anonymous call the anon role is granted succeeds", %{base: base} do
      resp = get!(base, "/rpc/getitemrange?min=2&max=4")

      assert resp.status == 200
      assert [%{"id" => 3}, %{"id" => 4}] = decode!(resp.body)
    end
  end
end
