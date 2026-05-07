defmodule BankWeb.Plugs.PutCSP do
  @moduledoc """
  Sets a strict Content-Security-Policy on HTML-rendering pipelines
  (audit M7).

  Phoenix's `put_secure_browser_headers/1` ships a permissive default
  CSP (`base-uri 'self'; frame-ancestors 'self';`) that doesn't
  constrain script / connect / object sources. This plug runs AFTER
  `put_secure_browser_headers` and overwrites the
  `content-security-policy` header with the project posture below.

  Wired into `:browser` and `:browser_session_json` only. The `:api`,
  `:internal_adapter`, and `:internal_telegram` pipelines do NOT
  render HTML and never reach a browser parser, so a CSP on those
  responses would be wasted bytes.

  ## Directives

    * `default-src 'self'` — fall-through deny everything cross-origin.
    * `script-src 'self'` — only first-party JS. The previously
      inline theme-init script was externalized to
      `assets/js/theme-init.js` so this can stay strict.
    * `style-src 'self' 'unsafe-inline'` — Phoenix LiveView injects
      per-element `style="..."` attributes via `phx-track-static` and
      hook lifecycles. Removing `'unsafe-inline'` here breaks LiveView
      transitions; this is documented Phoenix behavior. Hash- or
      nonce-based tightening is a follow-up gated on upstream support.
    * `img-src 'self' data:` — first-party images plus `data:` URIs
      for inline SVG / favicons embedded by build tools.
    * `connect-src 'self'` — covers the LiveView WebSocket upgrade at
      `/live/websocket` (same-origin) and the `/v1` fetch surface
      hit by the operator-console install hook.
    * `frame-ancestors 'none'` — clickjacking defense; the operator
      console must never be embeddable.
    * `base-uri 'self'` — base-tag injection defense.
    * `form-action 'self'` — prevents CSRF posts from being relayed
      to a third-party origin via a captured form.
    * `object-src 'none'` — drops Flash / legacy plugin attack
      surface entirely (no `<object>` / `<embed>` / `<applet>`).

  No `report-uri` / `report-to` for now — endpoint to receive reports
  isn't part of v0.1's surface.
  """

  import Plug.Conn

  @csp [
         "default-src 'self'",
         "script-src 'self'",
         "style-src 'self' 'unsafe-inline'",
         "img-src 'self' data:",
         "connect-src 'self'",
         "frame-ancestors 'none'",
         "base-uri 'self'",
         "form-action 'self'",
         "object-src 'none'"
       ]
       |> Enum.join("; ")

  def init(opts), do: opts

  def call(conn, _opts) do
    put_resp_header(conn, "content-security-policy", @csp)
  end
end
