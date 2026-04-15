defmodule BankWeb.PageController do
  use BankWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
