defmodule BankWeb.SessionHTML do
  @moduledoc """
  HTML templates for the login and pending-access pages.

  Tiny inline templates — these live in module functions instead
  of `.heex` files because v0.1 has only two simple pages and the
  full design system lands with issue #157.
  """

  use BankWeb, :html

  embed_templates "session_html/*"
end
