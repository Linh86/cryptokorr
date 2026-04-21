defmodule BankWeb.API.V1.ScreeningController do
  @moduledoc """
  `/v1/screening/:chain/:address` — wallet screening evidence lookup.

  Allows operators and API consumers to inspect wallet-screening
  evidence for a given chain+address pair. Returns the screening
  outcome, matched records by tier, provenance, and feed health.
  """

  use BankWeb, :controller

  alias Bank.WalletScreening.Evidence

  def show(conn, %{"chain" => chain, "address" => address}) do
    evidence = Evidence.for_address(chain, address)

    conn
    |> put_status(:ok)
    |> json(%{data: evidence})
  end
end
