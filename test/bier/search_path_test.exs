defmodule Bier.SearchPathTest do
  @moduledoc """
  `db-extra-search-path` used to be fully plumbed through config — typed,
  defaulted, env-mapped, CLI-parsed, rendered by `dump-config` — and then never
  applied to anything: no `SET search_path`, no `set_config`, nowhere in `lib/`
  (issue #105). Case 1728 covers only the *parsing* rule (an empty string yields
  `[]`), asserted against `dump-config`, so the conformance suite is
  structurally blind to the runtime half — upstream's own coverage for it lives
  in its IO tests, outside the frozen HTTP surface.

  Both halves of the fix are observed the same way upstream's IO test observes
  it (`postgrest.session.get("/rpc/get_guc_value?name=search_path")`), through
  the `test.get_guc_value(name text)` fixture:

    * every pooled connection starts with `search_path` set to the configured
      extras, so the setting has an effect even on instances with no auth
      configured (where a request never opens an auth transaction);
    * inside the per-request auth transaction the path is replaced with the
      *request's* schema followed by the extras — upstream's
      `iSchema : configDbExtraSearchPath` (`Query/PreQuery.hs`).

  Pre-fix both assertions see PostgreSQL's own default (`"$user", public`).
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  defp boot(instance_opts) do
    port = TestPorts.free_port()
    name = :"search_path_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(instance_opts,
        name: name,
        router: [port: port, scheme: :http],
        db_schemas: ["test"]
      )

    {:ok, pid} = Bier.start_link(opts)
    on_exit(fn -> stop(pid) end)
    TestPorts.wait_until_listening(port)
    "http://localhost:#{port}"
  end

  # The instance is linked to the test process, so ExUnit's own teardown can
  # already be tearing it down by the time on_exit runs; a racing stop exits
  # with :shutdown rather than :normal.
  defp stop(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp guc!(base, name) do
    resp =
      Req.request!(
        method: :get,
        url: base <> "/rpc/get_guc_value?name=" <> URI.encode_www_form(name),
        headers: [{"accept", "application/json"}],
        retry: false,
        decode_body: false
      )

    assert resp.status == 200
    Bier.json_library().decode!(resp.body)
  end

  describe "connection-level search_path (no auth configured)" do
    test "every pooled connection carries the configured extras" do
      base =
        Bier.ConformanceServer.base_opts()
        |> Keyword.put(:db_extra_search_path, ["public", "postgrest"])
        |> boot()

      assert guc!(base, "search_path") == ~s("public", "postgrest")
    end

    test "an empty extra search path leaves PostgreSQL's default alone" do
      base =
        Bier.ConformanceServer.base_opts()
        |> Keyword.put(:db_extra_search_path, [])
        |> boot()

      assert guc!(base, "search_path") == ~s("$user", public)
    end
  end

  describe "per-request search_path (auth transaction)" do
    test "the request's schema comes first, then the configured extras" do
      base =
        Bier.ConformanceServer.auth_opts()
        |> Keyword.merge(db_extra_search_path: ["public"], db_pre_request: nil)
        |> boot()

      assert guc!(base, "search_path") == ~s("test", "public")
    end
  end
end
