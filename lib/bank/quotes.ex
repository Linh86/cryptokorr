defmodule Bank.Quotes do
  @moduledoc """
  Quote and simulation provider integration.

  The control plane does not speak to chain-specific providers
  directly. It holds a small `Bank.Quotes.Provider` behaviour; the TS
  adapter fulfils the remote calls. In-process, we ship a
  `Bank.Quotes.StubProvider` for tests and local dev, and a
  `Bank.Quotes.AdapterClient` wrapper for production traffic (filled
  in by #10 in the adapter repo).

  `preview/2` is the single entry point used by the decision
  pipeline. It returns an `{:ok, %Preview{}}` summarising balance
  impact, fees, expected output, routing, and failure conditions, or
  `{:error, reason}` when a provider call fails / degrades.

  ## Failure-safe posture

  The decision engine never treats a degraded preview as permission to
  execute. `preview/2` failure modes:

    * `{:error, :provider_unavailable}` — network error or timeout;
      caller must surface `:hold` or `:block`, never `:auto_exec`.
    * `{:error, {:simulation_failed, reason}}` — the provider completed
      but the dry-run itself failed (revert, insufficient balance,
      etc); treat as a policy-level hard-stop.
    * `{:error, :stale}` — the previous preview is older than its TTL
      and a new one has not yet arrived; caller re-simulates.

  `Bank.Autonomy` (issue #17) encodes the degrade-toward-caution rule
  against these error atoms, so the provider module stays a pure
  translation layer.
  """

  alias Bank.Intents.AgentIntent
  alias Bank.Quotes.Preview

  @type error ::
          :provider_unavailable
          | :stale
          | {:simulation_failed, String.t()}
          | {:unsupported, String.t()}

  @type result :: {:ok, Preview.t()} | {:error, error()}

  @doc """
  Produce a quote + simulation preview for the given intent.

  Options:

    * `:provider` — override the configured provider module. Tests
      pass `Bank.Quotes.StubProvider` explicitly; production reads
      from `config :bank, Bank.Quotes`.
    * `:now` — override the wall clock for freshness calculation.
  """
  @spec preview(AgentIntent.t(), keyword()) :: result()
  def preview(%AgentIntent{} = intent, opts \\ []) do
    provider = Keyword.get(opts, :provider, configured_provider())

    with :ok <- validate_chain(intent.chain) do
      result =
        try do
          provider.preview(intent, opts)
        rescue
          e -> {:error, {:provider_exception, Exception.message(e)}}
        catch
          :exit, _ -> {:error, :provider_unavailable}
        end

      emit_preview_telemetry(provider, result)
      result
    end
  end

  defp emit_preview_telemetry(provider, result) do
    provider_tag =
      provider |> Module.split() |> List.last() |> String.downcase() |> String.to_atom()

    result_tag =
      case result do
        {:ok, _} -> :ok
        {:error, :provider_unavailable} -> :provider_unavailable
        {:error, :stale} -> :stale
        {:error, {:simulation_failed, _}} -> :simulation_failed
        {:error, {:unsupported, _}} -> :unsupported
        {:error, {:provider_exception, _}} -> :provider_exception
        {:error, _} -> :error
      end

    Bank.Runtime.Telemetry.preview(provider_tag, result_tag)
  end

  @doc """
  Returns `true` when the preview was produced more than
  `freshness_ttl_seconds` ago relative to `now`.
  """
  @spec stale?(Preview.t(), DateTime.t()) :: boolean()
  def stale?(%Preview{} = preview, now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(preview.generated_at, preview.freshness_ttl_seconds, :second)
    DateTime.compare(now, cutoff) != :lt
  end

  defp validate_chain("base"), do: :ok

  defp validate_chain(chain) when is_binary(chain),
    do: {:error, {:unsupported, "chain=#{chain} is not supported by v0.1 (base only)"}}

  defp configured_provider do
    Application.get_env(:bank, __MODULE__, [])[:provider] || Bank.Quotes.StubProvider
  end
end
