defmodule Bank.Quotes do
  @moduledoc """
  Quote and simulation provider integration.

  The control plane does not speak to chain-specific providers
  directly. It holds a small `Bank.Quotes.Provider` behaviour; live
  providers (#174) fulfil the remote calls. In-process, we ship a
  `Bank.Quotes.StubProvider` for tests and local dev, and the
  `Bank.Quotes.LiveProvider` skeleton (#173) that #174 will fill in
  without changing the integration seam below.

  `preview/2` is the single entry point used by the decision
  pipeline. It returns an `{:ok, %Preview{}}` summarising balance
  impact, fees, expected output, routing, risk flags, and failure
  conditions; or `{:error, reason}` when a provider call fails /
  degrades / is deliberately disabled.

  ## Provider selection (#173)

  The active provider is picked from `config :bank, Bank.Quotes,
  provider: ...`. Three symbolic modes are supported alongside the
  legacy "module name" form, so a deployment can flip between them
  via env without redeploying:

    * `:stub` — the deterministic in-process
      `Bank.Quotes.StubProvider`. Default in dev / test.
    * `:live` — the live network-backed
      `Bank.Quotes.LiveProvider`. Returns `{:error,
      :not_yet_implemented}` until #174 lands.
    * `:disabled` — short-circuits *before* the provider call and
      returns `{:error, :provider_disabled}`. Used to fail closed
      during incident response or in deployments where a live
      provider isn't available yet.
    * a module that implements `Bank.Quotes.Provider` — used
      directly. This keeps the existing call-site contract
      backwards-compatible: tests and adapters that pass an explicit
      `provider: SomeModule` opt continue to work.

  Tests pass `provider:` per call to override config without
  mutating `Application.get_env/2`.

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
    * `{:error, :provider_disabled}` — the deployment is configured
      with `provider: :disabled`. Same posture as
      `:provider_unavailable` for the autonomy rule (degrade toward
      caution); distinct atom so an operator can tell the two apart.
    * `{:error, :not_yet_implemented}` — the configured provider
      module hasn't been built yet (today: `Bank.Quotes.LiveProvider`
      pre-#174). Same caution posture, distinct atom for diagnostics.

  `Bank.Autonomy` (issue #17) encodes the degrade-toward-caution rule
  against these error atoms, so the provider module stays a pure
  translation layer.
  """

  alias Bank.Intents.AgentIntent
  alias Bank.Quotes.Preview

  @type error ::
          :provider_unavailable
          | :provider_disabled
          | :not_yet_implemented
          | :stale
          | {:simulation_failed, String.t()}
          | {:unsupported, String.t()}
          | {:provider_exception, String.t()}

  @type result :: {:ok, Preview.t()} | {:error, error()}

  @type provider_setting :: module() | :stub | :live | :disabled

  @doc """
  Produce a quote + simulation preview for the given intent.

  Options:

    * `:provider` — override the configured provider. Accepts a
      module that implements `Bank.Quotes.Provider`, or one of the
      symbolic atoms `:stub`, `:live`, `:disabled`. Tests pass
      `Bank.Quotes.StubProvider` (or `:stub`) explicitly; production
      reads from `config :bank, Bank.Quotes`.
    * `:now` — override the wall clock for freshness calculation.
  """
  @spec preview(AgentIntent.t(), keyword()) :: result()
  def preview(%AgentIntent{} = intent, opts \\ []) do
    setting = Keyword.get(opts, :provider, configured_provider())

    with :ok <- validate_chain(intent.chain),
         {:ok, provider} <- resolve_provider(setting) do
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
    else
      {:disabled, provider_tag} ->
        result = {:error, :provider_disabled}
        emit_preview_telemetry(provider_tag, result)
        result

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Resolve a provider setting (module or symbolic atom) to either an
  implementation module or a `:disabled` short-circuit signal.

  Returns:

    * `{:ok, module}` — caller delegates to `module.preview/2`.
    * `{:disabled, tag}` — caller short-circuits with
      `{:error, :provider_disabled}`. `tag` is an atom passed to
      telemetry so the disabled-mode count is observable.

  Exposed for downstream consumers that want to inspect the active
  provider without going through `preview/2` (e.g. `/ops`
  dashboards).
  """
  @spec resolve_provider(provider_setting()) ::
          {:ok, module()} | {:disabled, atom()}
  def resolve_provider(:stub), do: {:ok, Bank.Quotes.StubProvider}
  def resolve_provider(:live), do: {:ok, Bank.Quotes.LiveProvider}
  def resolve_provider(:disabled), do: {:disabled, :disabled}
  def resolve_provider(module) when is_atom(module), do: {:ok, module}

  defp emit_preview_telemetry(provider, result) do
    provider_tag =
      cond do
        is_atom(provider) and not is_nil(provider) and function_exported?(provider, :__info__, 1) ->
          provider |> Module.split() |> List.last() |> String.downcase() |> String.to_atom()

        is_atom(provider) ->
          provider

        true ->
          :unknown
      end

    result_tag =
      case result do
        {:ok, _} -> :ok
        {:error, :provider_unavailable} -> :provider_unavailable
        {:error, :provider_disabled} -> :provider_disabled
        {:error, :not_yet_implemented} -> :not_yet_implemented
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
