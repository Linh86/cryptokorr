defmodule Bank.Accounts.OAuthProvider.Stub do
  @moduledoc """
  Test/dev `Bank.Accounts.OAuthProvider` that never calls Google.

  Tests inject canned identity claims via `Application.put_env/3` (or
  per-call `:claims` opt) and the stub round-trips them through the
  controller as if Google had returned them. The `state` parameter
  is still verified against the session — that's a real CSRF
  property the tests want to pin.

  ## Configuration

      config :bank, Bank.Accounts.OAuthProvider, provider: #{inspect(__MODULE__)}

      # Per-test override (in setup/2):
      Application.put_env(:bank, #{inspect(__MODULE__)}, %{
        claims: %{
          provider: :google,
          subject: "google-stub-1",
          email: "alice@example.com",
          name: "Alice",
          avatar_url: nil
        }
      })

  Failure modes are still expressible:

      Application.put_env(:bank, #{inspect(__MODULE__)}, %{outcome: :provider_unavailable})
      Application.put_env(:bank, #{inspect(__MODULE__)}, %{outcome: {:provider_error, "..."}})

  Default outcome is `:ok` with a deterministic stub identity.
  """

  @behaviour Bank.Accounts.OAuthProvider

  @impl true
  def authorize_url(state, _opts) when is_binary(state) do
    case outcome() do
      :provider_unavailable ->
        {:error, :provider_unavailable}

      _ ->
        # Loop the browser back to the local callback so a controller
        # test that follows the redirect lands on the callback action.
        {:ok, "/auth/google/callback?code=stub-code&state=" <> URI.encode_www_form(state)}
    end
  end

  @impl true
  def fetch_user(%{} = params, expected_state, _opts) when is_binary(expected_state) do
    cfg = settings()

    cond do
      cfg[:outcome] == :provider_unavailable ->
        {:error, :provider_unavailable}

      match?({:provider_error, _}, cfg[:outcome]) ->
        {:error, cfg[:outcome]}

      Map.get(params, "state") != expected_state ->
        {:error, :invalid_state}

      not is_binary(Map.get(params, "code")) or Map.get(params, "code") == "" ->
        {:error, :missing_code}

      true ->
        {:ok, claims_or_default(cfg)}
    end
  end

  defp claims_or_default(cfg) do
    cfg[:claims] || default_claims()
  end

  defp default_claims do
    %{
      provider: :google,
      subject: "google-stub-default",
      email: "stub-default@example.com",
      name: "Stub Default",
      avatar_url: nil
    }
  end

  defp settings do
    Application.get_env(:bank, __MODULE__, %{})
    |> Map.new()
  end

  defp outcome, do: settings()[:outcome]
end
