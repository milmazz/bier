defmodule Bier.ErrorLogger do
  @moduledoc """
  Structured JSON diagnostics for database-client and schema-cache failures.

  PostgREST logs these conditions to stderr as a single JSON object with the
  keys of its error envelope — `code`, `message`, `details`, `hint`:

    * **PGRST001** — "Database client error. Retrying the connection." when the
      database connection is lost;
    * **PGRST002** — "Could not query the database for the schema cache.
      Retrying." when the schema-cache introspection fails on boot or reload.

  Bier emits the same envelope as the *message* of a `Logger.error/2` call, so
  the line lands in the host application's logging pipeline (level filtering,
  formatting, backends) instead of being written to a device the host cannot
  control. The message is built lazily — nothing is encoded when the `:error`
  level is disabled. Each entry also carries `:bier_instance` and
  `:bier_error_code` metadata for structured log pipelines.

  For PostgREST's exact behavior (the JSON line on stderr), point the default
  logger handler at standard error in the host application:

      config :logger, :default_handler, config: [type: :standard_error]
  """

  require Logger

  @doc """
  Log PGRST001 — the database client/connection error envelope.

  `reason` (an exception or any term) becomes the envelope's `details`.
  """
  @spec database_client_error(Bier.name(), term()) :: :ok
  def database_client_error(instance, reason) do
    log(instance, "PGRST001", "Database client error. Retrying the connection.", reason)
  end

  @doc """
  Log PGRST002 — the schema-cache introspection failure envelope.

  `reason` (an exception or any term) becomes the envelope's `details`.
  """
  @spec schema_cache_load_error(Bier.name(), term()) :: :ok
  def schema_cache_load_error(instance, reason) do
    log(
      instance,
      "PGRST002",
      "Could not query the database for the schema cache. Retrying.",
      reason
    )
  end

  defp log(instance, code, message, reason) do
    Logger.error(
      fn ->
        Bier.json_library().encode!(%{
          code: code,
          message: message,
          details: details(reason),
          hint: nil
        })
      end,
      bier_instance: instance,
      bier_error_code: code
    )
  end

  defp details(%{__exception__: true} = exception), do: Exception.message(exception)
  defp details(other), do: inspect(other)
end
