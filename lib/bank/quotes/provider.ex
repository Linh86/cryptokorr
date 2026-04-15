defmodule Bank.Quotes.Provider do
  @moduledoc """
  Behaviour implemented by quote / simulation providers.

  A provider translates an `%AgentIntent{}` into a `%Preview{}` or a
  structured error. Implementations must not raise for expected
  failure modes — raising bubbles to `Bank.Quotes.preview/2` which
  re-wraps as `{:error, :provider_unavailable}`, but explicit return
  values preserve diagnostic information.
  """

  alias Bank.Intents.AgentIntent
  alias Bank.Quotes.Preview

  @callback preview(intent :: AgentIntent.t(), opts :: keyword()) ::
              {:ok, Preview.t()} | {:error, Bank.Quotes.error()}
end
