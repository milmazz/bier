defmodule Bier.ConformanceCase do
  @moduledoc """
  A parsed `spec/cases/*.yaml` record. `load_all/0` reads every case
  file into a struct; the conformance generator enumerates these.
  """

  @enforce_keys [:id, :feature, :area, :kind, :request, :expect]
  defstruct [
    :id,
    :feature,
    :area,
    :kind,
    :request,
    :schema,
    :expect,
    :source,
    config: %{}
  ]

  @type t :: %__MODULE__{
          id: pos_integer(),
          feature: String.t(),
          area: String.t(),
          kind: :http | :cli,
          request: map(),
          schema: String.t() | nil,
          expect: map(),
          source: String.t() | nil,
          # PostgREST per-case config overrides (e.g. `openapi-mode: disabled`).
          # The runner boots a dedicated Bier instance per distinct config and
          # routes the case to it; `%{}` means the shared instance.
          config: map()
        }

  # test/support -> project root -> spec/cases
  @cases_dir Path.expand("../../spec/cases", __DIR__)

  @spec load_all() :: [t()]
  def load_all do
    @cases_dir
    |> Path.join("*.yaml")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&load_file/1)
  end

  defp load_file(path) do
    data = YamlElixir.read_from_file!(path)
    request = Map.get(data, "request", %{})
    feature = Map.get(data, "feature", "")

    %__MODULE__{
      id: Map.fetch!(data, "id"),
      feature: feature,
      area: feature |> String.split("/") |> List.first(),
      kind: if(Map.get(request, "kind") == "cli", do: :cli, else: :http),
      request: request,
      schema: Map.get(data, "schema"),
      expect: Map.get(data, "expect", %{}),
      source: Map.get(data, "source"),
      config: Map.get(data, "config") || %{}
    }
  end
end
