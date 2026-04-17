defmodule Bank.AdapterConfigTest do
  @moduledoc """
  Regression tests for the production adapter-config invariants
  introduced in issue #51.

  Phoenix and the TS adapter share a bearer secret read from
  `:bank, Bank.AdapterClient, :auth_secret`. If `config/config.exs` set
  a development default for that key, a misconfigured production boot
  would silently inherit the dev secret — leaving the inbound
  `/internal/adapter/callback` plug accepting a known token. The fix
  is to keep all adapter defaults in env-specific files (`dev.exs`,
  `test.exs`) and require env vars in `:prod` via `runtime.exs`.
  """

  use ExUnit.Case, async: true

  describe "compile-time config evaluated under :prod" do
    test "config/config.exs does not set Bank.AdapterClient defaults" do
      config =
        "config/config.exs"
        |> Path.expand(File.cwd!())
        |> Config.Reader.read!(env: :prod)

      bank_config = Keyword.get(config, :bank, [])

      refute Keyword.has_key?(bank_config, Bank.AdapterClient),
             "config/config.exs must not set :bank, Bank.AdapterClient — production must " <>
               "be supplied via ADAPTER_BASE_URL / ADAPTER_AUTH_SECRET env vars in " <>
               "config/runtime.exs. See issue #51."
    end
  end
end
