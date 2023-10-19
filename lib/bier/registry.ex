defmodule Bier.Registry do
  @moduledoc """
  Local key-value process storage for Bier instances
  """

  @type role :: term()
  @type value :: term()
  @type key :: Bier.name() | {Bier.name(), role}

  @doc false
  @spec child_spec(any()) :: Supervisor.child_spec()
  def child_spec(_) do
    Supervisor.child_spec(
      Registry.child_spec(keys: :unique, name: __MODULE__),
      id: __MODULE__
    )
  end

  @doc """
  Retrieves the configuration for a Bier instance

  ## Examples

  Get the default Bier instance configuration:

      Bier.Registry.config(Bier)
  """
  @spec config(Bier.name()) :: Bier.Config.t()
  def config(name) do
    [{_pid, config}] = Registry.lookup(__MODULE__, name)
    config
  end

  @doc """
  Returns the process identifier (pid) of a supervised Bier process

  If the given process can't be found, the returned value is `nil`.

  ## Examples

  Retrieves the Bier supervisor's pid:

      Bier.Registry.whereis(Bier)

  Get a supervised module's pid:

      Bier.Registry.whereis(Bier, Postgrex)
  """
  @spec whereis(Bier.name(), role()) :: pid() | nil
  def whereis(name, role \\ nil), do: name |> via(role) |> GenServer.whereis()

  @doc """
  Returns a _via tuple_ useful for processes name registration

  ## Examples

  To retrieve a suitable _via tuple_ for a Bier supervisor:

      Bier.Registry.via(Bier)

  In case you want to use the _via tuple_ to store process metadata you can proceed as follows:

      Bier.Registry.via(Bier, nil, config)
  """
  @spec via(Bier.name(), role(), value()) :: {:via, Registry, {__MODULE__, key()}}
  def via(name, role \\ nil, value \\ nil)
  def via(name, role, nil), do: {:via, Registry, {__MODULE__, key(name, role)}}

  def via(name, role, value), do: {:via, Registry, {__MODULE__, key(name, role), value}}

  defp key(name, nil), do: name
  defp key(name, role), do: {name, role}
end
