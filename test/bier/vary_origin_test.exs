defmodule Bier.VaryOriginTest do
  @moduledoc """
  `Vary: Origin` on CORS responses (#98) — a **deliberate divergence** from
  PostgREST v16.0, not a conformance fix.

  `Bier.Plugs.Cors` echoes the *request's* `Origin` into
  `Access-Control-Allow-Origin` rather than sending `*`, and a response whose
  headers depend on a request header must name that header in `Vary`
  (RFC 9111 §4.1). Upstream does not: it builds its policy with
  `corsVaryOrigin = False` (`Cors.hs`), so a shared cache may serve a response
  stamped for one origin to a request from another.

  The header is the **union** — `Accept, Prefer, Range, Origin` — appended
  inside the `Bier.Plugs.Vary` funnel. Setting a `Vary` in `Bier.Plugs.Cors`
  instead would *suppress* the v16 default on exactly the requests carrying an
  `Origin` (`put_resp_header/3` replaces, and the funnel skips a response that
  already carries a Vary), which is the collision that removed the CORS line in
  the first place.

  What must NOT change, all pinned by frozen cases:

    * a `response.headers` GUC-set `Vary` still replaces the default verbatim
      (case 1576);
    * error responses still carry no `Vary` at all (case 1583);
    * a request without `Origin` still gets the bare default (cases 1575/1582);
    * CORS preflight responses are left exactly as they were — upstream answers
      them in the wai-cors middleware, before `toWaiResponse`, so nothing about
      their `Vary` is Bier's to change here.

  A wildcard `Access-Control-Allow-Origin: *` does not get `Origin` either: it
  is not an echo, so the header it carries is the same for every origin.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  @default "Accept, Prefer, Range"
  @with_origin "Accept, Prefer, Range, Origin"

  @allowed "http://example.com"

  setup_all do
    opts = Bier.ConformanceServer.base_opts()

    allowlisted = boot(opts, server_cors_allowed_origins: "#{@allowed}, http://example2.com")
    permissive = boot(opts, server_cors_allowed_origins: "")

    %{base: allowlisted, wildcard: permissive}
  end

  defp boot(opts, extra) do
    port = TestPorts.free_port()
    name = :"vary_origin_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Bier.start_link(
        Keyword.merge(
          opts,
          # Two instances boot here; a small pool keeps the pair well inside the
          # server's connection limit when the whole suite runs.
          [name: name, router: [port: port, scheme: :http], pool_size: 2] ++ extra
        )
      )

    on_exit(fn -> stop(pid) end)
    TestPorts.wait_until_listening(port)
    "http://localhost:#{port}"
  end

  defp stop(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp request!(method, base, path, headers) do
    Req.request!(
      method: method,
      url: base <> path,
      headers: headers,
      retry: false,
      decode_body: false
    )
  end

  defp vary(resp), do: resp.headers["vary"]

  describe "an echoed Origin joins the default Vary" do
    test "a read from an allowlisted origin", %{base: base} do
      resp = request!(:get, base, "/items?limit=1", [{"origin", @allowed}])

      assert resp.status == 200
      assert resp.headers["access-control-allow-origin"] == [@allowed]
      assert vary(resp) == [@with_origin]
    end

    test "an OPTIONS that is not a preflight", %{base: base} do
      resp = request!(:options, base, "/items", [{"origin", @allowed}])

      assert resp.status == 200
      assert resp.headers["access-control-allow-origin"] == [@allowed]
      assert vary(resp) == [@with_origin]
    end
  end

  describe "everything else keeps the bare v16 default" do
    test "no Origin at all (cases 1575/1582)", %{base: base} do
      assert vary(request!(:get, base, "/items?limit=1", [])) == [@default]
      assert vary(request!(:options, base, "/items", [])) == [@default]
    end

    test "an Origin outside the allowlist gets no CORS header and no Origin (case 1704)", %{
      base: base
    } do
      resp = request!(:get, base, "/items?limit=1", [{"origin", "http://evil.example"}])

      assert resp.headers["access-control-allow-origin"] == nil
      assert vary(resp) == [@default]
    end

    test "a wildcard allow-origin is not an echo (case 1703)", %{wildcard: base} do
      resp = request!(:get, base, "/items?limit=1", [{"origin", @allowed}])

      assert resp.headers["access-control-allow-origin"] == ["*"]
      assert vary(resp) == [@default]
    end
  end

  describe "the two properties the funnel already pins survive" do
    test "a GUC-set Vary still replaces the default verbatim (case 1576)", %{base: base} do
      resp =
        request!(:get, base, "/rpc/get_vary_header_override", [
          {"accept", "application/json"},
          {"origin", @allowed}
        ])

      assert resp.status == 200
      assert vary(resp) == ["Accept, Prefer, X-Test-Vary"]
    end

    test "an error response still carries no Vary (case 1583)", %{base: base} do
      resp =
        request!(:get, base, "/parents", [
          {"accept-profile", "unknown"},
          {"origin", @allowed}
        ])

      assert resp.status == 406
      assert vary(resp) == nil
    end
  end

  describe "preflight responses are left alone" do
    test "a preflight carries the same Vary it did before", %{base: base} do
      resp =
        request!(:options, base, "/items", [
          {"origin", @allowed},
          {"access-control-request-method", "POST"},
          {"access-control-request-headers", "Content-Type"}
        ])

      assert resp.status == 200
      assert resp.headers["access-control-allow-origin"] == [@allowed]
      assert resp.headers["access-control-max-age"] == ["86400"]
      assert vary(resp) == [@default]
    end
  end
end
