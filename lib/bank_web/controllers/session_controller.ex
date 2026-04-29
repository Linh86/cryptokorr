defmodule BankWeb.SessionController do
  @moduledoc """
  Renders the unauthenticated login page and the placeholder
  pending-access page (epic #153, issue #154).

  The real pending-access UI ships with issue #157; this module
  reserves the `/login` and `/pending` routes so the auth flow can
  redirect to them and the layout/test surface is in place when
  #157 lands.
  """

  use BankWeb, :controller

  def login(conn, _params) do
    conn
    |> assign(:page_title, "Sign in")
    |> render(:login, layout: false)
  end

  def pending(conn, _params) do
    conn
    |> assign(:page_title, "Pending access")
    |> render(:pending, layout: false)
  end
end
