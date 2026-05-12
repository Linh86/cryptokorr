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
    * `connect-src 'self' <bundler-origin>` — covers the LiveView
      WebSocket upgrade at `/live/websocket` (same-origin), the
      `/v1` fetch surface, AND the operator-console install hook's
      direct call to the configured ERC-4337 bundler. The bundler
      origin comes from `Bank.SessionPermissions.BrowserInstall`'s
      `:bundler_rpc_url` (extracted to `scheme://host[:port]`) so
      a config change auto-propagates to the CSP — there is no
      hardcoded bundler URL in this plug. When that config is
      missing, falls back to a small allowlist of known
      browser-friendly bundler hosts so a half-configured dev env
      doesn't break the install flow silently with `Failed to fetch`.
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

  # Fallback hosts the install hook may need to reach when
  # `Bank.SessionPermissions.BrowserInstall :bundler_rpc_url` is
  # missing from the env. Kept small on purpose — any host added
  # here becomes a permitted fetch target for the whole operator
  # console. The deployed config should always set
  # `:bundler_rpc_url` so this fallback is only for half-configured
  # dev sessions.
  @fallback_bundler_origins [
    "https://api.pimlico.io",
    "https://rpc.zerodev.app"
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    put_resp_header(conn, "content-security-policy", build_csp())
  end

  @doc false
  def build_csp do
    [
      "default-src 'self'",
      "script-src 'self'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data:",
      build_connect_src(),
      "frame-ancestors 'none'",
      "base-uri 'self'",
      "form-action 'self'",
      "object-src 'none'"
    ]
    |> Enum.join("; ")
  end

  defp build_connect_src do
    configured =
      [configured_bundler_origin(), configured_chain_rpc_origin()]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    origins =
      case configured do
        [] -> @fallback_bundler_origins
        list -> list
      end

    "connect-src 'self' " <> Enum.join(origins, " ")
  end

  @doc false
  def configured_bundler_origin do
    configured_origin(:bundler_rpc_url)
  end

  # Generic chain RPC origin (e.g. `https://sepolia.base.org`). The
  # install hook builds a viem `publicClient` against this URL for
  # `getSenderAddress` simulation — without permitting it in
  # `connect-src`, the browser blocks the `eth_call` with
  # `Failed to fetch` before the SDK can read the simulated revert.
  # Always returned in addition to the bundler origin so both
  # transports can fire.
  @doc false
  def configured_chain_rpc_origin do
    configured_origin(:chain_rpc_url)
  end

  defp configured_origin(key) do
    case Application.get_env(:bank, Bank.SessionPermissions.BrowserInstall, [])
         |> Keyword.get(key) do
      url when is_binary(url) and byte_size(url) > 0 ->
        url_to_origin(url)

      _ ->
        nil
    end
  end

  defp url_to_origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when is_binary(scheme) and is_binary(host) and byte_size(host) > 0 ->
        scheme <> "://" <> host <> port_suffix(scheme, port)

      _ ->
        nil
    end
  end

  defp port_suffix("https", 443), do: ""
  defp port_suffix("http", 80), do: ""
  defp port_suffix(_, port) when is_integer(port), do: ":#{port}"
  defp port_suffix(_, _), do: ""
end
