defmodule Bier.JwtCacheTest do
  # async: false — the "integration (booted instance)" describe block below
  # boots real Bier instances (real Bandit listeners + DB introspection),
  # matching the precedent in test/bier/telemetry_test.exs and other
  # instance-booting test files in this suite.
  use ExUnit.Case, async: false

  describe "config" do
    test "jwt_cache_max_entries defaults to 1000 (PostgREST parity)" do
      conf = Bier.Config.new!([], Bier.schema())
      assert conf.jwt_cache_max_entries == 1000
    end

    test "jwt_cache_max_entries is configurable, 0 disables" do
      conf = Bier.Config.new!([jwt_cache_max_entries: 0], Bier.schema())
      assert conf.jwt_cache_max_entries == 0
    end
  end

  describe "telemetry helpers" do
    test "jwt_cache_lookup/2 and jwt_cache_eviction/1 emit the #36 events" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:bier, :jwt_cache, :lookup],
          [:bier, :jwt_cache, :eviction]
        ])

      Bier.Telemetry.jwt_cache_lookup(true, %{instance: Some.Instance})
      Bier.Telemetry.jwt_cache_lookup(false, %{instance: Some.Instance})
      Bier.Telemetry.jwt_cache_eviction(%{instance: Some.Instance})

      assert_receive {[:bier, :jwt_cache, :lookup], ^ref, %{count: 1},
                      %{hit: true, instance: Some.Instance}}

      assert_receive {[:bier, :jwt_cache, :lookup], ^ref, %{count: 1},
                      %{hit: false, instance: Some.Instance}}

      assert_receive {[:bier, :jwt_cache, :eviction], ^ref, %{count: 1},
                      %{instance: Some.Instance}}
    end
  end

  describe "Bier.JwtCache" do
    # A verify_fun stub that notifies the test process every time the
    # "expensive" verification actually runs.
    defp counting_fun(test_pid, tag, result) do
      fn ->
        send(test_pid, {:verified, tag})
        result
      end
    end

    defp start_cache(max_entries) do
      name = Module.concat(__MODULE__, "C#{System.unique_integer([:positive])}")

      conf =
        Bier.Config.new!(
          [
            name: name,
            jwt_secret: "reallyreallyreallyreallyverysafe",
            jwt_cache_max_entries: max_entries
          ],
          Bier.schema()
        )

      pid = start_supervised!({Bier.JwtCache, conf})
      {name, pid}
    end

    defp attach_cache_events(name) do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:bier, :jwt_cache, :lookup],
          [:bier, :jwt_cache, :eviction]
        ])

      {ref, name}
    end

    test "enabled?/1 requires a secret and a positive max" do
      base = [jwt_secret: "reallyreallyreallyreallyverysafe"]
      assert Bier.JwtCache.enabled?(Bier.Config.new!(base, Bier.schema()))

      refute Bier.JwtCache.enabled?(
               Bier.Config.new!(base ++ [jwt_cache_max_entries: 0], Bier.schema())
             )

      refute Bier.JwtCache.enabled?(Bier.Config.new!([], Bier.schema()))
    end

    test "a miss verifies and inserts; the second fetch is a served-from-cache hit" do
      {name, _pid} = start_cache(10)
      {ref, _} = attach_cache_events(name)
      ok = {:ok, %{"role" => "a"}, ~s({"role":"a"})}

      assert ^ok = Bier.JwtCache.fetch(name, "tok1", counting_fun(self(), :t1, ok))
      assert_receive {:verified, :t1}

      assert_receive {[:bier, :jwt_cache, :lookup], ^ref, %{count: 1},
                      %{hit: false, instance: ^name}}

      assert ^ok = Bier.JwtCache.fetch(name, "tok1", counting_fun(self(), :t1, ok))
      refute_receive {:verified, :t1}, 50

      assert_receive {[:bier, :jwt_cache, :lookup], ^ref, %{count: 1},
                      %{hit: true, instance: ^name}}
    end

    test "errors are never cached" do
      {name, _pid} = start_cache(10)
      err = {:error, :jwt_invalid}

      assert ^err = Bier.JwtCache.fetch(name, "bad", counting_fun(self(), :bad, err))
      assert ^err = Bier.JwtCache.fetch(name, "bad", counting_fun(self(), :bad, err))
      assert_receive {:verified, :bad}
      assert_receive {:verified, :bad}
    end

    test "SIEVE: at capacity the oldest unvisited entry is evicted; a visited one survives" do
      {name, _pid} = start_cache(2)
      {ref, _} = attach_cache_events(name)
      ok = fn tag -> {:ok, %{"t" => tag}, ~s({"t":"#{tag}"})} end

      # Fill: t1 (older), t2 (newer). Then hit t1 to set its visited bit.
      # Drain each initial miss's :verified message immediately so it can't
      # linger in the mailbox and falsely satisfy a later assert_receive /
      # refute_receive on the same tag.
      assert {:ok, _, _} = Bier.JwtCache.fetch(name, "t1", counting_fun(self(), :t1, ok.("t1")))
      assert_receive {:verified, :t1}
      assert {:ok, _, _} = Bier.JwtCache.fetch(name, "t2", counting_fun(self(), :t2, ok.("t2")))
      assert_receive {:verified, :t2}
      assert {:ok, _, _} = Bier.JwtCache.fetch(name, "t1", counting_fun(self(), :t1, ok.("t1")))

      # Insert t3: the hand starts at the tail (t1), finds it visited, clears
      # the bit and advances to t2, which is unvisited -> evicted.
      assert {:ok, _, _} = Bier.JwtCache.fetch(name, "t3", counting_fun(self(), :t3, ok.("t3")))
      assert_receive {[:bier, :jwt_cache, :eviction], ^ref, %{count: 1}, %{instance: ^name}}

      # t1 survived (hit, no re-verification); t2 was evicted (re-verifies).
      assert {:ok, _, _} = Bier.JwtCache.fetch(name, "t1", counting_fun(self(), :t1, ok.("t1")))
      refute_receive {:verified, :t1}, 50
      assert {:ok, _, _} = Bier.JwtCache.fetch(name, "t2", counting_fun(self(), :t2, ok.("t2")))
      assert_receive {:verified, :t2}
    end

    test "fetch falls back to direct verification when no cache is running" do
      ok = {:ok, %{}, "{}"}
      name = Module.concat(__MODULE__, "NoCache#{System.unique_integer([:positive])}")
      assert ^ok = Bier.JwtCache.fetch(name, "tok", counting_fun(self(), :nc, ok))
      assert_receive {:verified, :nc}
    end

    test "stopping the cache erases its persistent_term entry" do
      {name, pid} = start_cache(10)
      ok = {:ok, %{}, "{}"}
      assert ^ok = Bier.JwtCache.fetch(name, "tok", fn -> ok end)

      :ok = stop_supervised!(Bier.JwtCache)
      refute Process.alive?(pid)
      assert :persistent_term.get({Bier, :jwt_cache, name}, nil) == nil
    end
  end

  describe "integration (booted instance)" do
    @auth_token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoicG9zdGdyZXN0X3Rlc3RfYXV0aG9yIiwiaWQiOiJqZG9lIn0.B-lReuGNDwAlU1GOC476MlO0vAt9JNoHIlxg2vwMaO0"

    defp start_listening_instance(name, extra_opts) do
      port = free_port()

      {:ok, pid} =
        Bier.start_link(
          [name: name, router: [port: port, scheme: :http]] ++
            Keyword.merge(Bier.ConformanceServer.base_opts(), extra_opts)
        )

      on_exit(fn -> stop(pid) end)
      wait_until_listening(port)
      {"http://127.0.0.1:#{port}", pid}
    end

    defp authed_get(base, token) do
      Req.get!(base <> "/authors_only",
        headers: [
          {"accept-profile", "auth"},
          {"authorization", "Bearer " <> token}
        ],
        retry: false
      )
    end

    test "authenticated requests go through the cache: miss then hit" do
      name = unique_name()
      {base, _pid} = start_listening_instance(name, [])

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:bier, :jwt_cache, :lookup]])

      assert authed_get(base, @auth_token).status == 200
      assert_receive {[:bier, :jwt_cache, :lookup], ^ref, _, %{hit: false, instance: ^name}}

      assert authed_get(base, @auth_token).status == 200
      assert_receive {[:bier, :jwt_cache, :lookup], ^ref, _, %{hit: true, instance: ^name}}
    end

    test "a cache hit still fails temporal validation (expired token -> 401 PGRST303)" do
      name = unique_name()
      {base, _pid} = start_listening_instance(name, [])

      # Pre-insert an expired entry under a token whose signature was never
      # checked: the hit path skips the signature (by design, mirroring
      # upstream), so the 401 proves validate_claims runs per request.
      token = "cached.expired.token"
      claims = %{"role" => "postgrest_test_author", "exp" => 1}

      :ok =
        GenServer.call(
          Bier.Registry.via(name, Bier.JwtCache),
          {:insert, token, claims, Bier.json_library().encode!(claims)}
        )

      resp = authed_get(base, token)
      assert resp.status == 401
      assert resp.body["code"] == "PGRST303"
    end

    test "jwt_cache_max_entries: 0 disables the cache: no child, no events" do
      name = unique_name()
      {base, _pid} = start_listening_instance(name, jwt_cache_max_entries: 0)

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:bier, :jwt_cache, :lookup]])

      assert Registry.lookup(Bier.Registry, {name, Bier.JwtCache}) == []
      assert :persistent_term.get({Bier, :jwt_cache, name}, nil) == nil

      assert authed_get(base, @auth_token).status == 200
      refute_receive {[:bier, :jwt_cache, :lookup], ^ref, _, %{instance: ^name}}, 100
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
