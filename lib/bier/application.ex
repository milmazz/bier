defmodule Bier.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Bier.CLI.Config

  @impl true
  def start(_type, _args) do
    children = [Bier.Registry | standalone_children(System.get_env())]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bier.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # When `BIER_STANDALONE` is set, boot one Bier instance from `PGRST_*` env via
  # the CLI config loader — this is how the release / Docker image runs Bier as a
  # standalone service. Inert otherwise, so the test suite and host apps that
  # embed Bier via `Bier.start_link/1` are unaffected. A fatal config problem
  # aborts boot with the message on stderr (fail fast, like PostgREST).
  @doc false
  def standalone_children(env) do
    case standalone_spec(env) do
      :none ->
        []

      {:ok, child} ->
        [child]

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  # Pure decision split out from `standalone_children/1` so it is testable
  # without halting the VM: returns `:none`, `{:ok, child_spec}`, or
  # `{:error, message}`.
  @doc false
  def standalone_spec(env) do
    if env["BIER_STANDALONE"] in ["1", "true"] do
      # validated_start_opts runs Bier's own boot schema so values the parse
      # layer tolerates (e.g. db-max-rows=0) fail here with a message instead
      # of crashing Bier.start_link/1 mid-supervision-tree.
      with {:ok, resolved} <- Config.load(env, nil, %{}),
           {:ok, opts} <- Config.validated_start_opts(resolved) do
        {:ok, {Bier, opts}}
      end
    else
      :none
    end
  end
end
