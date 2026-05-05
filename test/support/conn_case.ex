defmodule BankWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use BankWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint BankWeb.Endpoint

      use BankWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import BankWeb.ConnCase
    end
  end

  setup tags do
    Bank.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Test setup helper for routes gated by
  `BankWeb.LiveAuth.:require_workspace` (#157). Inserts a fresh
  user with a single active workspace membership and returns a
  `conn` whose session points at that user.

  Test files that need to mount an operator LiveView (`/`,
  `/dashboard`, ...) opt in by adding
  `setup :register_and_log_in_user` near the top of the file.
  Returns `{:ok, %{conn: conn, current_user: user, workspace:
  workspace}}` so individual tests can pattern-match on the setup
  map when they need the user / workspace ids.
  """
  def register_and_log_in_user(context),
    do: register_and_log_in_user_with_role(context, :operator)

  @doc """
  Same as `register_and_log_in_user/1` but with a custom membership
  role (#159a). Tests that exercise admin-only actions
  (pause/resume/revoke, archive) call this with `:admin`; tests for
  the role-gate redirects call it with `:viewer` or other roles.
  """
  def register_and_log_in_user_as_admin(context),
    do: register_and_log_in_user_with_role(context, :admin)

  def register_and_log_in_user_as_viewer(context),
    do: register_and_log_in_user_with_role(context, :viewer)

  def register_and_log_in_user_with_role(%{conn: conn} = _context, role)
      when role in [:viewer, :operator, :admin, :owner] do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "test-user-#{suffix}",
        email: "test-user-#{suffix}@example.com",
        name: "Test User #{suffix}"
      })

    # Default the test workspace to mainnet-enabled so existing tests
    # that use the canonical `chain: "base"` fixture (which is a
    # mainnet-class chain per `Bank.Chains.mainnet_chains/0`, #178)
    # keep passing without per-test setup. Tests that exercise the
    # mainnet gate explicitly create a workspace with
    # `mainnet_enabled: false` (or call
    # `Bank.Workspaces.set_mainnet_enabled/2`) to verify rejection.
    {:ok, workspace} =
      Bank.Workspaces.create_workspace(%{
        slug: "test-ws-#{suffix}",
        name: "Test workspace #{suffix}",
        mainnet_enabled: true
      })

    {:ok, _} =
      Bank.Workspaces.create_membership(%{
        user_id: user.id,
        workspace_id: workspace.id,
        role: role
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    # Stash the workspace id in the process dict so `Bank.Fixtures`
    # can stamp `workspace_id` on every workspace-scoped row by
    # default (#158c). The on_exit cleanup keeps tests isolated even
    # in non-async cases. Tests that need cross-workspace fixtures
    # pass `workspace_id:` explicitly to override.
    Process.put(:bank_test_workspace_id, workspace.id)
    ExUnit.Callbacks.on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

    {:ok, conn: conn, current_user: user, workspace: workspace}
  end

  @doc """
  Test wrapper around `Bank.Delegations.grant/3` that defaults
  `:workspace_id` from the process-dict slot
  `register_and_log_in_user/1` populates (#158c). Tests that bypass
  the LiveView wiring path use this so the resulting row has the
  same workspace scope every other fixture sets.

  Pass `workspace_id:` in `attrs` to override.
  """
  def grant_delegation(smart_account_id, delegation_id, attrs \\ %{}) do
    attrs = Map.put_new(attrs, :workspace_id, Process.get(:bank_test_workspace_id))
    Bank.Delegations.grant(smart_account_id, delegation_id, attrs)
  end

  @doc """
  Bumps the file-level user's membership role to `:admin` (#159a).
  Use as a `describe`-level `setup :upgrade_to_admin_role` for
  individual blocks that exercise admin-only handle_event callbacks
  (`pause_runtime`, `archive`, etc.) — keeps the rest of the file's
  tests on the default operator role so we get coverage of both
  tiers without creating a second user/workspace per describe.
  """
  def upgrade_to_admin_role(%{current_user: user, workspace: workspace} = context) do
    {:ok, membership} =
      Bank.Workspaces.get_membership(user, workspace.id)
      |> Bank.Workspaces.set_role(:admin)

    {:ok, Map.put(context, :membership, membership)}
  end

  @doc """
  Setup helper for `/v1` controller tests gated by
  `BankWeb.Plugs.VerifyAPIKey` (#218b). Mints an API key with the
  given role and returns a `conn` whose Authorization header is
  set to `Bearer cb_<...>`.

  Also stashes the workspace id in the process dict so
  `Bank.Fixtures` stamps every workspace-scoped row to the same
  workspace by default (consistent with the LiveView path from
  #158c).

  Returns context updated with `:conn`, `:current_user`,
  `:workspace`, `:api_key`, and `:raw_api_key`.
  """
  def setup_api_key_admin(context), do: setup_api_key_with_role(context, :admin)

  def setup_api_key_operator(context), do: setup_api_key_with_role(context, :operator)

  def setup_api_key_viewer(context), do: setup_api_key_with_role(context, :viewer)

  def setup_api_key_with_role(%{conn: conn} = _context, role)
      when role in [:viewer, :operator, :admin, :owner] do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "ak-test-#{suffix}",
        email: "ak-test-#{suffix}@example.com",
        name: "API Key Test #{suffix}"
      })

    {:ok, workspace} =
      Bank.Workspaces.create_workspace(%{
        slug: "ak-test-ws-#{suffix}",
        name: "API Key Test WS #{suffix}",
        mainnet_enabled: true
      })

    # Always grant the user :admin in their workspace so the test
    # creator has authority to mint any role of API key. This is
    # the test-side trust-boundary handoff documented on
    # `Bank.APIKeys.create_key/4`.
    {:ok, _} =
      Bank.Workspaces.create_membership(%{
        user_id: user.id,
        workspace_id: workspace.id,
        role: :admin
      })

    {:ok, api_key, raw_secret} =
      Bank.APIKeys.create_key(workspace, user, role, "test-key-#{suffix}")

    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> raw_secret)

    Process.put(:bank_test_workspace_id, workspace.id)
    ExUnit.Callbacks.on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

    {:ok,
     conn: conn,
     current_user: user,
     workspace: workspace,
     api_key: api_key,
     raw_api_key: raw_secret}
  end
end
