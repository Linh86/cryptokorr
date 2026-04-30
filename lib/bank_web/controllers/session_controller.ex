defmodule BankWeb.SessionController do
  @moduledoc """
  Renders the unauthenticated login page and the pending-access
  page (epic #153, issues #154 + #157).

  The pending-access action classifies the current user via
  `Bank.Access.classify_pending/1` so the template can render
  context-specific copy:

    * `:domain_match` — a live domain invite is waiting for admin
      approval.
    * `:allowlist_missed` — no live invite at all.
    * `:exact_match_pending` — corner case (live exact-email
      invite that didn't auto-accept).

  Plus two states the classification doesn't need to compute:

    * `:ambiguous` — multiple active memberships; a workspace
      picker (issue #162) hasn't shipped yet.
    * `:default` — anonymous, no current_user, or a fresh login
      that hasn't classified yet.
  """

  use BankWeb, :controller

  alias Bank.Access
  alias Bank.Workspaces

  def login(conn, _params) do
    conn
    |> assign(:page_title, "Sign in")
    |> render(:login, layout: false)
  end

  def pending(conn, _params) do
    user = conn.assigns[:current_user]

    {classification, invite} = build_classification(user)

    conn
    |> assign(:page_title, "Pending access")
    |> assign(:pending_classification, classification)
    |> assign(:pending_invite, invite)
    |> render(:pending, layout: false)
  end

  defp build_classification(nil), do: {:default, nil}

  defp build_classification(user) do
    case Workspaces.resolve_scope(user) do
      {:ambiguous, _memberships} ->
        {:ambiguous, nil}

      _ ->
        # `resolve_scope` is `:no_membership` (the practical case
        # here) or `{:single, _}`. The auth-controller redirect
        # makes a `{:single, _}` user land on `/`, not `/pending`,
        # so the path that reaches us is the no-membership one.
        row = Access.classify_pending(user)
        {row.classification, row.invite}
    end
  end
end
