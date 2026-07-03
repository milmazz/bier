defmodule Bier.MediaType do
  @moduledoc """
  Accept/Content-Type media-type negotiation, mirroring PostgREST's
  `PostgREST.MediaType`.

  A parsed media type is a `%Bier.MediaType{}` struct carrying the canonical
  symbol (`:json`, `:csv`, `:singular`, `:array_strip`, …), the rendered MIME
  string (`toMime`), and any preserved parameters (plan `for`/`options`, the
  `nulls=stripped` flag, etc.).

  Negotiation (`negotiate/2`) takes the request's ordered `Accept` preferences
  and the set of media types a producer can emit, and returns the first
  acceptable one (client order wins), or `:not_acceptable`.
  """

  @enforce_keys [:symbol, :mime]
  defstruct symbol: nil, mime: nil, params: %{}

  @type t :: %__MODULE__{symbol: atom(), mime: String.t(), params: map()}

  @doc """
  Parse one media type token (no q-value handling) into a struct, or `nil` for
  an unrecognized custom/unknown token (still tracked so `*/*` can rescue it).
  """
  def decode(token) when is_binary(token) do
    {base, params} = split_params(token)
    decode_base(String.downcase(String.trim(base)), params)
  end

  defp decode_base("application/json", _params),
    do: %__MODULE__{symbol: :json, mime: "application/json"}

  defp decode_base("application/geo+json", _params),
    do: %__MODULE__{symbol: :geojson, mime: "application/geo+json"}

  defp decode_base("text/csv", _params), do: %__MODULE__{symbol: :csv, mime: "text/csv"}

  defp decode_base("text/plain", _params), do: %__MODULE__{symbol: :text, mime: "text/plain"}

  defp decode_base("text/tab-separated-values", _params),
    do: %__MODULE__{symbol: :tsv, mime: "text/tab-separated-values"}

  defp decode_base("application/octet-stream", _params),
    do: %__MODULE__{symbol: :octet, mime: "application/octet-stream"}

  defp decode_base("application/openapi+json", _params),
    do: %__MODULE__{symbol: :openapi, mime: "application/openapi+json"}

  defp decode_base("*/*", _params), do: %__MODULE__{symbol: :any, mime: "*/*"}

  defp decode_base("application/vnd.pgrst.object", params), do: singular(params)
  defp decode_base("application/vnd.pgrst.object+json", params), do: singular(params)

  defp decode_base("application/vnd.pgrst.array", params), do: array(params)
  defp decode_base("application/vnd.pgrst.array+json", params), do: array(params)

  defp decode_base("application/vnd.pgrst.plan", params), do: plan(:text, params)
  defp decode_base("application/vnd.pgrst.plan+text", params), do: plan(:text, params)
  defp decode_base("application/vnd.pgrst.plan+json", params), do: plan(:json, params)

  defp decode_base(other, params), do: %__MODULE__{symbol: :other, mime: other, params: params}

  defp singular(params) do
    strip? = Map.get(params, "nulls") == "stripped"
    %__MODULE__{symbol: :singular, mime: singular_mime(strip?), params: %{strip: strip?}}
  end

  defp singular_mime(false), do: "application/vnd.pgrst.object+json"
  defp singular_mime(true), do: "application/vnd.pgrst.object+json;nulls=stripped"

  # A bare `application/vnd.pgrst.array+json` (no nulls=stripped) decodes back to
  # plain JSON (PostgREST: it is not a distinct producer). Only the stripped form
  # is a separate media type.
  defp array(params) do
    if Map.get(params, "nulls") == "stripped" do
      %__MODULE__{
        symbol: :array_strip,
        mime: "application/vnd.pgrst.array+json;nulls=stripped",
        params: %{strip: true}
      }
    else
      %__MODULE__{symbol: :json, mime: "application/json"}
    end
  end

  # Plan media type: `for=` defaults to application/json; `options=` echoed.
  defp plan(format, params) do
    for_type =
      case Map.get(params, "for") do
        nil -> "application/json"
        raw -> raw |> unquote_param() |> decode() |> Map.get(:mime)
      end

    options = Map.get(params, "options")

    %__MODULE__{
      symbol: :plan,
      mime: "application/vnd.pgrst.plan",
      params: %{format: format, for: for_type, options: options}
    }
  end

  defp unquote_param(<<?", _::binary>> = v) do
    v |> String.trim_leading("\"") |> String.trim_trailing("\"")
  end

  defp unquote_param(v), do: v

  # Split "type/subtype; a=b; c=d" -> {"type/subtype", %{"a"=>"b","c"=>"d"}}.
  defp split_params(token) do
    [base | rest] = String.split(token, ";")

    params =
      rest
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Map.new(&param_pair/1)

    {base, params}
  end

  defp param_pair(part) do
    case String.split(part, "=", parts: 2) do
      [k, v] -> {String.downcase(String.trim(k)), String.trim(v)}
      [k] -> {String.downcase(String.trim(k)), ""}
    end
  end

  @doc """
  Parse an `Accept` header into an ordered list of `%Bier.MediaType{}` entries.
  Order follows client order (PostgREST does not reorder by q-value); a `q=0`
  entry is dropped.
  """
  def parse_accept(nil), do: [%__MODULE__{symbol: :any, mime: "*/*"}]
  def parse_accept(""), do: [%__MODULE__{symbol: :any, mime: "*/*"}]

  def parse_accept(header) do
    header
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or q_zero?(&1)))
    |> Enum.map(&decode/1)
  end

  defp q_zero?(token) do
    {_base, params} = split_params(token)
    Map.get(params, "q") in ["0", "0.0", "0.00", "0.000"]
  end

  @doc """
  Render the response `Content-Type` value for a resolved media type. `charset`
  controls whether `; charset=utf-8` is appended — every type except
  octet-stream / custom (`:other`) / `:any` carries the charset.
  """
  def content_type(%__MODULE__{symbol: :octet}), do: "application/octet-stream"
  def content_type(%__MODULE__{symbol: :any}), do: "application/octet-stream"
  def content_type(%__MODULE__{symbol: :other, mime: mime}), do: mime

  def content_type(%__MODULE__{symbol: :plan} = mt) do
    %{format: format, for: for_type, options: options} = mt.params
    suffix = if format == :json, do: "+json", else: "+text"

    base = ~s(application/vnd.pgrst.plan#{suffix}; for="#{for_type}")
    base = if options, do: base <> "; options=#{options}", else: base
    base <> "; charset=utf-8"
  end

  def content_type(%__MODULE__{mime: mime}), do: mime <> "; charset=utf-8"

  @doc """
  Negotiate the client's ordered `Accept` preferences against the producer's
  available media types (a list of symbols). Returns `{:ok, %MediaType{}}` for
  the first acceptable preference (client order wins), or `:not_acceptable`.

  `*/*` matches the producer's default (first available). A specific preference
  listed before `*/*` overrides `*/*`.
  """
  def negotiate(accepts, available) when is_list(accepts) and is_list(available) do
    Enum.find_value(accepts, :not_acceptable, fn mt ->
      cond do
        mt.symbol == :any ->
          {:ok, default_for(available)}

        mt.symbol in available ->
          {:ok, mt}

        true ->
          false
      end
    end)
  end

  # The default media type a producer emits for `*/*` is its first available.
  defp default_for([first | _]), do: %__MODULE__{symbol: first, mime: mime_for(first)}

  defp mime_for(:json), do: "application/json"
  defp mime_for(:csv), do: "text/csv"
  defp mime_for(:geojson), do: "application/geo+json"
  defp mime_for(:octet), do: "application/octet-stream"
  defp mime_for(:openapi), do: "application/openapi+json"
  defp mime_for(:text), do: "text/plain"
  defp mime_for(sym), do: to_string(sym)
end
