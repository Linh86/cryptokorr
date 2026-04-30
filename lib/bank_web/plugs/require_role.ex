defmodule BankWeb.Plugs.RequireRole do
  @moduledoc """
  HTTP role gate (#218b) — the API-side counterpart to
  `BankWeb.LiveAuth.{:require_role, role}` from #159a.

  Reads `conn.assigns.current_scope.role` and refuses the request
  with 403 if it does not satisfy the required role under the
  authority order `viewer < operator < admin < owner`. The check
  is delegated to `Bank.Workspaces.Membership.role_at_least?/2`
  so session- and key-authenticated requests share one comparator.

  ## Pipeline contract

  This plug REQUIRES that an upstream plug
  (`BankWeb.Plugs.VerifyAPIKey` for `/v1`, or any future session-
  based plug for browser HTTP) has already populated
  `conn.assigns.current_scope.role`. If `current_scope` is
  missing the plug returns 401 — that is a configuration error,
  not an authorization decision.

  ## Usage

  Either pipe-style in the router (`plug BankWeb.Plugs.RequireRole,
  :operator`) or inline at the controller / pipeline level. Either
  way `init/1` accepts the bare role atom and validates it against
  the same enum the live-side gate uses; an unknown role raises at
  router compile time, not at request time.

  ## Wire response

    * `401 unauthenticated` if `current_scope` or `current_scope.role`
      is missing — the upstream plug failed to authenticate but its
      branch was somehow skipped, which is a config bug.
    * `403 insufficient_role` with the required role name in the
      body so a tooling consumer can adapt without re-reading the
      route table.
  """

  import Plug.Conn

  alias Bank.Workspaces.Membership

  @valid_roles [:viewer, :operator, :admin, :owner]

  def init(role) when role in @valid_roles, do: role

  def init(role) do
    raise ArgumentError,
          "BankWeb.Plugs.RequireRole expects one of #{inspect(@valid_roles)}, got: #{inspect(role)}"
  end

  def call(conn, required_role) do
    scope = conn.assigns[:current_scope]
    actual_role = scope && Map.get(scope, :role)

    cond do
      is_nil(scope) ->
        halt_with(conn, :unauthorized, "unauthenticated")

      Membership.role_at_least?(actual_role, required_role) ->
        conn

      true ->
        halt_with(conn, :forbidden, "insufficient_role", %{required_role: required_role})
    end
  end

  defp halt_with(conn, status, code, extras \\ %{}) do
    body =
      Map.merge(
        %{error: %{code: code}},
        Map.new(extras, fn {k, v} -> {k, atom_or_value(v)} end)
      )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp atom_or_value(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_or_value(value), do: value
end
