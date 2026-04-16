defmodule BankWeb.Layouts do
  @moduledoc """
  Application layouts and layout components for the Bank control tower.
  """
  use BankWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders the control tower app shell.

  This is the outermost frame for every page: a fixed sidebar for
  navigation and a scrolling main area for content.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div id="app-shell" class="flex h-screen bg-base-100">
      <%!-- Sidebar --%>
      <aside
        id="sidebar"
        class="hidden lg:flex flex-col w-64 border-r border-base-300 bg-base-200/50"
      >
        <div class="flex items-center gap-3 px-5 py-5 border-b border-base-300">
          <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-primary text-primary-content font-bold text-sm">
            B
          </div>
          <div>
            <p class="text-sm font-semibold tracking-tight">Bank v0.1</p>
            <p class="text-[0.65rem] text-base-content/50 uppercase tracking-widest">
              Control Tower
            </p>
          </div>
        </div>

        <nav class="flex-1 px-3 py-4 space-y-1">
          <.nav_item href="/" icon="hero-signal" label="Connection" active />
          <.nav_item href="#" icon="hero-document-text" label="Intents" disabled />
          <.nav_item href="#" icon="hero-scale" label="Policies" disabled />
          <.nav_item href="#" icon="hero-users" label="Counterparties" disabled />
          <.nav_item href="#" icon="hero-queue-list" label="Action Queue" disabled />
          <.nav_item href="#" icon="hero-document-magnifying-glass" label="Audit" disabled />
        </nav>

        <div class="px-3 py-4 border-t border-base-300">
          <.theme_toggle />
        </div>
      </aside>

      <%!-- Main --%>
      <div class="flex-1 flex flex-col min-w-0 overflow-hidden">
        <%!-- Top bar (mobile & desktop) --%>
        <header class="flex items-center justify-between h-14 px-4 lg:px-6 border-b border-base-300 bg-base-100/80 backdrop-blur-sm shrink-0">
          <div class="flex items-center gap-3 lg:hidden">
            <div class="flex items-center justify-center w-7 h-7 rounded-md bg-primary text-primary-content font-bold text-xs">
              B
            </div>
            <span class="text-sm font-semibold">Bank v0.1</span>
          </div>
          <div class="hidden lg:block" />
          <div class="flex items-center gap-2">
            <span class="badge badge-sm badge-ghost font-mono text-[0.65rem]">Base</span>
            <span class="badge badge-sm badge-ghost font-mono text-[0.65rem]">USDC</span>
            <div class="lg:hidden"><.theme_toggle /></div>
          </div>
        </header>

        <%!-- Scrollable content area --%>
        <main class="flex-1 overflow-y-auto">
          <div class="mx-auto max-w-5xl px-4 py-6 lg:px-8 lg:py-8">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  # --- Nav helpers ----------------------------------------------------------

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :disabled, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <a
      href={unless @disabled, do: @href}
      class={[
        "flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors",
        @active && "bg-primary/10 text-primary",
        !@active && !@disabled && "text-base-content/70 hover:bg-base-300/50 hover:text-base-content",
        @disabled && "text-base-content/30 cursor-not-allowed"
      ]}
    >
      <.icon name={@icon} class="size-4 shrink-0" />
      <span>{@label}</span>
      <span :if={@disabled} class="ml-auto text-[0.6rem] uppercase tracking-wider opacity-50">
        Soon
      </span>
    </a>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
