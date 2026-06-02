defmodule Bier.ConformanceServerTest do
  use ExUnit.Case, async: true

  test "base_url/0 returns the running instance URL and it answers HTTP" do
    base = Bier.ConformanceServer.base_url()
    assert base =~ ~r{^http://127\.0\.0\.1:\d+$}

    # Unknown path -> Bier returns *some* response (canned/404), proving it's up.
    resp = Req.request!(method: :get, url: base <> "/__definitely_unknown__", retry: false)
    assert resp.status in 100..599
  end
end
