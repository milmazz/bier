defmodule Bier.Plugs.Warning do
  @moduledoc """
  Emits PostgREST v16.0's deprecation `Warning` header for legacy embed target
  names.

  When a `select` aliases an embedded resource (`the_tasks:tasks(...)`) a
  filter, order or limit may still address it by the *relation* name
  (`tasks.name=like.Code*`). v16.0 kept that working under the default
  `url-use-legacy-target-names = true` but marked it deprecated: the read plan
  records the legacy match (`relIsLegacyTargetNameMatch`, `Plan.hs`), and
  `App.hs`' `toWaiResponse` appends one header naming every replacement:

      299 <product-token> "Embedded resource was referenced by relation name
      even though it has an alias. This is deprecated and will stop working in a
      future release. Update `tasks` to `the_tasks` in query string filters,
      orders or limits."

  Two properties are reproduced here:

    * **One header per response, from a single funnel.** Upstream builds it in
      `toWaiResponse` from the whole plan, so several legacy matches collapse
      into one header whose replacement list is comma-joined — hence a
      `register_before_send/2` callback fed by `record/2` rather than a header
      set at each rendering site.

    * **It is a deprecation notice, not an error.** Addressing the embed by its
      alias sets no flag and emits no header, and with
      `url-use-legacy-target-names = false` the request is rejected outright
      instead of warned about (so nothing is recorded either).

  `299` is the RFC 7234 "miscellaneous persistent warning" code; the product
  token identifies the emitting server (upstream uses `PostgRESTv<version>`).
  """

  @behaviour Plug

  import Plug.Conn

  alias Bier.Plugs.Vary

  @assign :bier_legacy_target_names

  @message "Embedded resource was referenced by relation name even though it has an alias. This is deprecated and will stop working in a future release."

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: register_before_send(conn, &put_warning/1)

  @doc """
  Record the aliased embeds `plan` addressed by their relation name, so the
  response carries the deprecation `Warning`.

  The pairs are the ones `Bier.Embed.resolve_target_names/2` recorded while
  resolving the request's embed paths. A no-op when the request used no legacy
  target name — including when `url-use-legacy-target-names` is off, since then
  the legacy spelling is an error rather than a warning and nothing resolves.
  Which is why the config is not a parameter: the gating already happened during
  resolution, so there is nothing left here to gate on.
  """
  @spec record(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def record(conn, plan) do
    case Map.get(plan, :legacy_target_names, []) do
      [] -> conn
      pairs -> assign(conn, @assign, pairs)
    end
  end

  # Like `Vary`, the header is appended by the non-error funnel only: an error
  # response is built by `Bier.Plugs.FallbackController` and carries neither.
  defp put_warning(conn) do
    pairs = conn.assigns[@assign]

    if pairs && not Vary.error_response?(conn) do
      put_resp_header(conn, "warning", header_value(pairs))
    else
      conn
    end
  end

  defp header_value(pairs) do
    hint = Enum.map_join(pairs, ", ", fn {name, alias_} -> "`#{name}` to `#{alias_}`" end)

    ~s(299 #{product_token()} "#{@message} Update #{hint} in query string filters, orders or limits.")
  end

  # Upstream's token is `"PostgRESTv" <> prettyVersion` with spaces stripped, so
  # it stays a single RFC 7234 `warn-agent` token whatever the version string
  # looks like. Bier emits the same shape under its own name.
  defp product_token do
    "Bierv" <> String.replace(Bier.version(), " ", "")
  end
end
