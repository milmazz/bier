defmodule Bier.Config do
  @moduledoc """
  Defines and validates the internal configuration needed by `Bier` processes.

  The options given to `Bier.start_link/1` are validated via `new!/2` using the
  internal schema, if the given options are valid, the configuration will be
  wrapped in a #{__MODULE__} struct, which subsequently will be stored in the
  `Bier.Registry`. Internal modules will also consume this configuration to work
  properly.
  """

  @typedoc """
  Options given to `Bandit`
  """
  @type router_opts :: [
          port: pos_integer(),
          scheme: :http | :https
        ]

  @type t :: %__MODULE__{
          name: module(),
          router: router_opts()
        }

  defstruct [
    :router,
    name: Bier
  ]

  @doc """
  Validates the given options based on the internal schema definition

  In case the given options are valid, it returns a `Bier.Config` struct,
  otherwise it will raise an exception.
  """
  @spec new!(Keyword.t(), Keyword.t()) :: t() | no_return()
  def new!(opts, schema) do
    conf = NimbleOptions.validate!(opts, schema)

    struct!(__MODULE__, conf)
  end
end
