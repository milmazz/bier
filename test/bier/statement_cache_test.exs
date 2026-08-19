defmodule Bier.StatementCacheTest do
  # async: false — the "integration (booted instance)" describe block below
  # boots real Bier instances (real Bandit listeners + DB introspection),
  # matching the precedent in test/bier/telemetry_test.exs and other
  # instance-booting test files in this suite.
  use ExUnit.Case, async: false

  describe "config" do
    test "db_prepared_statements defaults to true (PostgREST parity)" do
      conf = Bier.Config.new!([], Bier.schema())
      assert conf.db_prepared_statements == true
    end

    test "db_prepared_statements can be disabled" do
      conf = Bier.Config.new!([db_prepared_statements: false], Bier.schema())
      assert conf.db_prepared_statements == false
    end
  end

  describe "Bier.StatementCache.opts/2" do
    test "disabled: no query options" do
      assert Bier.StatementCache.opts(false, "SELECT 1") == []
    end

    test "enabled: a deterministic bier_-prefixed cache_statement name" do
      [cache_statement: name] = Bier.StatementCache.opts(true, "SELECT 1")

      assert String.starts_with?(name, "bier_")
      # Postgres identifier limit is 63 bytes; the name must always fit.
      assert byte_size(name) <= 63
      assert Bier.StatementCache.opts(true, "SELECT 1") == [cache_statement: name]
      assert Bier.StatementCache.opts(true, "SELECT 2") != [cache_statement: name]
    end
  end

  describe "integration (booted instance)" do
    # A verified HS256 token for the auth-area fixtures (same constant as
    # test/bier/jwt_cache_test.exs): role postgrest_test_author.
    @auth_token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoicG9zdGdyZXN0X3Rlc3RfYXV0aG9yIiwiaWQiOiJqZG9lIn0.B-lReuGNDwAlU1GOC476MlO0vAt9JNoHIlxg2vwMaO0"

    # pool_size: 1 pins every request (and our introspection query below) to
    # ONE backend session, so pg_prepared_statements — a session-local view —
    # deterministically shows what the request path prepared.
    defp start_listening_instance(name, base_opts, extra_opts) do
      port = free_port()

      {:ok, pid} =
        Bier.start_link(
          [name: name, router: [port: port, scheme: :http]] ++
            Keyword.merge(base_opts, Keyword.merge([pool_size: 1], extra_opts))
        )

      on_exit(fn -> stop(pid) end)
      wait_until_listening(port)
      {"http://127.0.0.1:#{port}", pid}
    end

    defp cached_statement_names(name) do
      {:ok, %{rows: rows}} =
        Postgrex.query(
          Bier.Registry.via(name, Postgrex),
          "SELECT name FROM pg_prepared_statements WHERE name LIKE 'bier_%'",
          []
        )

      List.flatten(rows)
    end

    defp authed_get(base) do
      Req.get!(base <> "/authors_only",
        headers: [
          {"accept-profile", "auth"},
          {"authorization", "Bearer " <> @auth_token}
        ],
        retry: false
      )
    end

    test "enabled: the auth preamble and read statements land in the backend cache" do
      name = unique_name()
      {base, _pid} = start_listening_instance(name, Bier.ConformanceServer.auth_opts(), [])

      assert authed_get(base).status == 200

      names = cached_statement_names(name)
      assert names != []

      # A second identical request must reuse the cache, not grow it.
      assert authed_get(base).status == 200
      assert cached_statement_names(name) == names
    end

    test "disabled: no statements are cached" do
      name = unique_name()

      {base, _pid} =
        start_listening_instance(name, Bier.ConformanceServer.auth_opts(),
          db_prepared_statements: false
        )

      assert authed_get(base).status == 200
      assert cached_statement_names(name) == []
    end

    test "reads, mutations and RPC cache their statements without an auth context too" do
      name = unique_name()
      {base, _pid} = start_listening_instance(name, Bier.ConformanceServer.base_opts(), [])

      assert Req.get!(base <> "/complex_items?id=eq.1", retry: false).status == 200
      read_names = cached_statement_names(name)
      assert read_names != []

      # base_opts uses db_tx_end: :rollback, so the write leaves no data behind
      # — but protocol-level prepared statements are session-scoped and survive
      # the rollback.
      assert Req.post!(base <> "/items", json: %{id: 90_001}, retry: false).status in [200, 201]

      assert Req.get!(base <> "/rpc/getitemrange?min=0&max=2", retry: false).status == 200

      assert length(cached_statement_names(name)) > length(read_names)
    end
  end

  # ---- helpers (booted-instance tests) -------------------------------------
  # Copied verbatim from test/bier/telemetry_test.exs.

  defp unique_name do
    Module.concat(__MODULE__, "I#{System.unique_integer([:positive])}")
  end

  # The instance supervisor is linked to the test process, so it may already be
  # terminating by the time this on_exit cleanup runs; `Supervisor.stop/1` then
  # exits rather than raising. Swallow both so cleanup never fails the test.
  defp stop(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp wait_until_listening(port, retries \\ 100) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 10) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _} when retries > 0 ->
        Process.sleep(20)
        wait_until_listening(port, retries - 1)

      {:error, reason} ->
        raise "instance did not come up on port #{port}: #{inspect(reason)}"
    end
  end
end
