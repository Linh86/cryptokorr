defmodule BankWeb.APIKeysAdminLive do
  @moduledoc """
  Admin surface for workspace API key management (#218 / `/admin/api_keys`).

  Lists the current workspace's keys, creates new keys (showing
  the raw secret EXACTLY ONCE on success), and soft-revokes
  existing keys.

  ## Auth

  Mounts under the bootstrap `:admin` live_session
  (`:require_admin`, BANK_ADMIN_EMAILS allowlist) — same
  posture as the `/admin/access` surface. The mount also
  refuses users who reach the page without an active workspace
  (no membership / ambiguous multi-workspace) by redirecting to
  `/pending`, so the page never has to handle a nil workspace.

  Note that the API surface (`/v1/api_keys`) gates on workspace
  role, NOT BANK_ADMIN_EMAILS. The two are different sets by
  design: workspace-role admins can mint keys via API; only
  bootstrap admins can use this UI. Future work can collapse
  the gap once workspace-role admins are first-class.

  ## Creator-privilege check

  `Bank.APIKeys.create_key/4` is documented (since #218a) as
  trusting its caller. This LiveView is the trust boundary:
  before calling `create_key`, it checks
  `Bank.Workspaces.Membership.role_at_least?(creator_role,
  requested_role)` so an admin caller cannot mint an `:owner`
  key. Mirrors the API controller's check.

  ## Secret hygiene

  The raw secret returned by `create_key/4` is stored in
  socket assigns under `:raw_key` for the lifetime of the
  one-time display panel only. Operator dismisses the panel
  via the "I've stored it" button (handle_event
  `"dismiss_raw_key"`), at which point the assign is cleared
  to `nil`. The raw secret is never persisted in DB, never
  written to audit (the existing `api_key.created` builder
  uses an allowlist snapshot — see #218a), never logged.

  ## DOM ids

    * `#api-keys-page` — wrapper for tests / E2E selectors.
    * `#api-key-create-form` — the create form.
    * `#api-key-name`, `#api-key-role`, `#api-key-expires-at` —
      form input ids.
    * `#api-key-raw-secret` — one-time raw-secret panel (reused
      by both create and rotate).
    * `#api-key-list` — list wrapper.
    * `#api-key-row-<id>` — per-row anchor.
    * `#api-key-rotate-<id>` — per-row rotate button (#220).
    * `#api-key-revoke-<id>` — per-row revoke button.
  """

  use BankWeb, :live_view

  alias Bank.APIKeys
  alias Bank.Workspaces.Membership

  @valid_roles ~w(viewer operator admin owner)

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_scope do
      %{workspace: %_{} = _ws} ->
        {:ok,
         socket
         |> assign(:page_title, "API keys")
         |> assign(:raw_key, nil)
         |> assign(:create_error, nil)
         |> assign_form(%{"name" => "", "role" => "viewer", "expires_at" => ""})
         |> load_keys()}

      _ ->
        {:ok, redirect(socket, to: "/pending")}
    end
  end

  @impl true
  def handle_event("validate", %{"api_key" => params}, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("create", %{"api_key" => params}, socket) do
    %{user: creator, workspace: workspace, role: caller_role} = socket.assigns.current_scope

    with {:ok, role} <- parse_role(params),
         :ok <- enforce_creator_role(caller_role, role),
         {:ok, name} <- parse_name(params),
         {:ok, expires_at} <- parse_expires_at(params),
         opts = if(expires_at, do: [expires_at: expires_at], else: []),
         {:ok, key, raw_secret} <- APIKeys.create_key(workspace, creator, role, name, opts) do
      {:noreply,
       socket
       |> assign(:raw_key, %{prefix: key.prefix, secret: raw_secret, name: key.name})
       |> assign(:create_error, nil)
       |> assign_form(%{"name" => "", "role" => "viewer", "expires_at" => ""})
       |> load_keys()
       |> put_flash(:info, "API key created — copy the raw secret below before dismissing.")}
    else
      {:error, :forbidden_role_above_creator} ->
        {:noreply,
         socket
         |> assign(:create_error, "You can only mint keys at or below your own role.")
         |> assign_form(params)}

      {:error, code} when is_binary(code) ->
        {:noreply,
         socket
         |> assign(:create_error, code)
         |> assign_form(params)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> assign(:create_error, "Could not create the key — check the form fields.")
         |> assign_form(params)}
    end
  end

  def handle_event("dismiss_raw_key", _params, socket) do
    {:noreply,
     socket
     |> assign(:raw_key, nil)
     |> put_flash(:info, "Raw secret dismissed. Make sure you copied it.")}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    workspace_id = socket.assigns.current_scope.workspace.id
    actor = socket.assigns.current_scope.user

    with {:ok, key} <- APIKeys.get_workspace_key(workspace_id, id),
         {:ok, _revoked} <- APIKeys.revoke_key(key, actor: actor) do
      {:noreply,
       socket
       |> load_keys()
       |> put_flash(:info, "Revoked #{key.name} (#{key.prefix}).")}
    else
      {:error, :not_found} ->
        # Cross-workspace or genuinely-unknown id — refuse with
        # a flash but DO NOT confirm existence (#218c
        # `get_workspace_key/2` returns the same shape for
        # both).
        {:noreply, put_flash(socket, :error, "API key not found.")}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke the key.")}
    end
  end

  def handle_event("rotate", %{"id" => id}, socket) do
    workspace_id = socket.assigns.current_scope.workspace.id
    actor = socket.assigns.current_scope.user

    with {:ok, old_key} <- APIKeys.get_workspace_key(workspace_id, id),
         {:ok, new_key, raw_secret} <- APIKeys.rotate_key(old_key, actor) do
      {:noreply,
       socket
       |> assign(:raw_key, %{
         prefix: new_key.prefix,
         secret: raw_secret,
         name: new_key.name
       })
       |> load_keys()
       |> put_flash(
         :info,
         "Rotated #{old_key.name} (#{old_key.prefix}) — copy the new raw secret below before dismissing."
       )}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "API key not found.")}

      {:error, :already_revoked} ->
        # Old key was revoked between the page render and this
        # click — the row should refresh into a "Revoked" state.
        {:noreply,
         socket
         |> load_keys()
         |> put_flash(:error, "Cannot rotate a revoked key.")}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Failed to rotate the key.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <main id="api-keys-page" class="mx-auto max-w-5xl space-y-6 p-6">
        <header class="space-y-1">
          <p class="text-xs uppercase tracking-widest text-base-content/50">
            Workspace administration
          </p>
          <h1 class="text-2xl font-semibold tracking-tight">API keys</h1>
          <p class="text-sm text-base-content/70">
            Manage workspace-scoped API keys for the <code>/v1</code> surface.
            Raw secrets are shown <strong>once</strong> on creation and never
            again — copy them immediately.
          </p>
        </header>

        <%= if @raw_key do %>
          <section
            id="api-key-raw-secret"
            class="rounded-md border border-amber-400 bg-amber-100/30 p-4 space-y-3"
          >
            <header class="flex items-center justify-between gap-4">
              <div>
                <h2 class="text-sm font-semibold tracking-tight">
                  New API key created — copy the secret now
                </h2>
                <p class="text-xs text-base-content/70">
                  This is the only time the raw secret will be shown. After
                  dismissing this panel it cannot be retrieved.
                </p>
              </div>
              <button
                id="api-key-raw-dismiss"
                phx-click="dismiss_raw_key"
                class="btn btn-sm btn-outline"
              >
                I've stored it
              </button>
            </header>
            <dl class="grid grid-cols-3 gap-3 text-sm">
              <div>
                <dt class="text-xs uppercase tracking-widest text-base-content/50">Name</dt>
                <dd class="font-mono">{@raw_key.name}</dd>
              </div>
              <div>
                <dt class="text-xs uppercase tracking-widest text-base-content/50">Prefix</dt>
                <dd class="font-mono">{@raw_key.prefix}</dd>
              </div>
              <div class="col-span-3">
                <dt class="text-xs uppercase tracking-widest text-base-content/50">Raw secret</dt>
                <dd
                  id="api-key-raw-secret-value"
                  class="break-all font-mono rounded bg-base-200 p-2"
                >
                  {@raw_key.secret}
                </dd>
              </div>
            </dl>
          </section>
        <% end %>

        <section
          id="api-key-create-form-section"
          class="rounded-md border border-base-300 bg-base-200 p-4 space-y-3"
        >
          <h2 class="text-sm font-semibold tracking-tight">Create key</h2>
          <.form
            id="api-key-create-form"
            for={@form}
            phx-change="validate"
            phx-submit="create"
            class="grid grid-cols-1 gap-3 md:grid-cols-4"
          >
            <.input
              id="api-key-name"
              field={@form[:name]}
              label="Name"
              placeholder="ci-runner"
              required
            />
            <.input
              id="api-key-role"
              field={@form[:role]}
              type="select"
              label="Role"
              options={role_options(@current_scope)}
              required
            />
            <.input
              id="api-key-expires-at"
              field={@form[:expires_at]}
              type="datetime-local"
              label="Expires at (optional)"
            />
            <div class="flex items-end">
              <button type="submit" class="btn btn-primary btn-sm">Create</button>
            </div>
          </.form>
          <%= if @create_error do %>
            <p id="api-key-create-error" class="text-xs text-rose-600">{@create_error}</p>
          <% end %>
        </section>

        <section class="space-y-3">
          <h2 class="text-sm font-semibold tracking-tight">Workspace keys</h2>

          <%= if @keys == [] do %>
            <div
              id="api-key-list-empty"
              class="rounded-md border border-base-300 bg-base-200 p-6 text-sm"
            >
              No API keys yet.
            </div>
          <% else %>
            <ul id="api-key-list" class="space-y-2">
              <li
                :for={key <- @keys}
                id={"api-key-row-" <> key.id}
                class="rounded-md border border-base-300 bg-base-200 p-3"
              >
                <div class="grid grid-cols-1 gap-2 md:grid-cols-6 md:items-center md:gap-3">
                  <div class="md:col-span-2">
                    <div class="font-medium">{key.name}</div>
                    <div class="font-mono text-xs text-base-content/60">
                      cb_{key.prefix}…
                    </div>
                  </div>
                  <div class="text-xs">
                    <span class="rounded bg-base-300 px-2 py-1 font-mono">
                      {Atom.to_string(key.role)}
                    </span>
                  </div>
                  <div class="text-xs text-base-content/70">
                    Created {format_time(key.inserted_at)}
                  </div>
                  <div class="text-xs text-base-content/70">
                    {render_status(assigns, key)}
                  </div>
                  <div class="flex justify-end gap-2">
                    <%= if is_nil(key.revoked_at) do %>
                      <button
                        id={"api-key-rotate-" <> key.id}
                        phx-click="rotate"
                        phx-value-id={key.id}
                        data-confirm={"Rotate #{key.name}? The old secret stops working immediately."}
                        class="btn btn-sm btn-outline"
                      >
                        Rotate
                      </button>
                      <button
                        id={"api-key-revoke-" <> key.id}
                        phx-click="revoke"
                        phx-value-id={key.id}
                        data-confirm={"Revoke #{key.name}? This is irreversible."}
                        class="btn btn-sm btn-outline btn-error"
                      >
                        Revoke
                      </button>
                    <% else %>
                      <span class="text-xs uppercase tracking-widest text-rose-700">
                        Revoked
                      </span>
                    <% end %>
                  </div>
                </div>
              </li>
            </ul>
          <% end %>
        </section>
      </main>
    </Layouts.app>
    """
  end

  # --- helpers ------------------------------------------------------------

  defp render_status(assigns, key) do
    assigns = assign(assigns, :key, key)

    ~H"""
    <%= cond do %>
      <% @key.revoked_at -> %>
        Revoked {format_time(@key.revoked_at)}
      <% match?(%DateTime{}, @key.last_used_at) -> %>
        Used {format_time(@key.last_used_at)}
      <% true -> %>
        Never used
    <% end %>
    """
  end

  defp role_options(%{role: caller_role}) do
    # An admin caller sees viewer/operator/admin; an owner
    # caller sees the full set. A non-admin (which the
    # `:require_admin` mount gate normally excludes) sees only
    # `viewer` as a defensive fallback.
    Enum.filter(@valid_roles, fn role_str ->
      Membership.role_at_least?(caller_role || :viewer, String.to_existing_atom(role_str))
    end)
    |> Enum.map(&{String.capitalize(&1), &1})
  end

  defp parse_role(%{"role" => role}) when role in @valid_roles,
    do: {:ok, String.to_existing_atom(role)}

  defp parse_role(_), do: {:error, "invalid_role"}

  defp parse_name(%{"name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, "name is required"}
      trimmed when byte_size(trimmed) > 255 -> {:error, "name is too long"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_name(_), do: {:error, "name is required"}

  # Empty / missing → no expiry. The HTML `datetime-local` input
  # emits values as `YYYY-MM-DDTHH:MM` (local time, no zone, no
  # seconds), which `DateTime.from_iso8601/1` does NOT accept.
  # Append `:00Z` so the value is interpreted as UTC — operators
  # who need a different zone can persist via the `/v1/api_keys`
  # API directly with a fully-qualified ISO8601 timestamp.
  defp parse_expires_at(%{"expires_at" => v}) when is_binary(v) do
    case String.trim(v) do
      "" ->
        {:ok, nil}

      trimmed ->
        normalised =
          if String.match?(trimmed, ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/) do
            trimmed <> ":00Z"
          else
            trimmed
          end

        case DateTime.from_iso8601(normalised) do
          {:ok, dt, _} -> {:ok, dt}
          _ -> {:error, "expires_at is not a valid datetime"}
        end
    end
  end

  defp parse_expires_at(_), do: {:ok, nil}

  defp enforce_creator_role(creator_role, requested_role) do
    if Membership.role_at_least?(creator_role, requested_role) do
      :ok
    else
      {:error, :forbidden_role_above_creator}
    end
  end

  defp load_keys(socket) do
    keys = APIKeys.list_keys_with_creator(socket.assigns.current_scope.workspace.id)
    assign(socket, :keys, keys)
  end

  defp assign_form(socket, params) do
    form = Phoenix.Component.to_form(params, as: :api_key)
    assign(socket, :form, form)
  end

  defp format_time(nil), do: "—"

  defp format_time(%DateTime{} = ts) do
    Calendar.strftime(ts, "%Y-%m-%d %H:%M UTC")
  end
end
