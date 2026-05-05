defmodule Bank.Notifications.Channel.Stub do
  @moduledoc """
  No-op delivery channel (#236).

  Returns `{:ok, %{provider: "stub"}}` for every call so the
  delivery state machine has a deterministic happy path under
  test. Real channel implementations (SMTP, webhook HTTP,
  Telegram client) land in follow-up issues.

  Test override: tests that need to drive a failure path can
  set `Bank.Notifications.Channel.Stub` config:

      Application.put_env(:bank, Bank.Notifications.Channel.Stub,
        result: {:error, :transport_error})

  The stub reads the override on every call. Defaults to
  `{:ok, %{provider: "stub"}}` when no override is set.
  """

  @behaviour Bank.Notifications.Channel

  @impl true
  def deliver(_notification, _payload, _opts) do
    case Application.get_env(:bank, __MODULE__, []) |> Keyword.get(:result) do
      nil -> {:ok, %{provider: "stub"}}
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
      {:permanent_error, _} = perm -> perm
    end
  end
end
