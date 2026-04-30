defmodule BankWeb.API.V1.APIKeyJSON do
  @moduledoc """
  JSON renderers for `/v1/api_keys*` (#218c).

  ## Secret hygiene contract

  The raw secret is included EXACTLY ONCE: in the `created/1`
  response, under `raw_key`. Every other render — `index/1`,
  `entity/1`, and the implicit serialization of an `%APIKey{}`
  struct — is built from a hard-coded field list (see
  `entity/1`) so a future column added to `Bank.APIKeys.APIKey`
  cannot silently leak into a list response.
  """

  alias Bank.APIKeys.APIKey

  @doc "`GET /v1/api_keys` envelope."
  def index(%{keys: keys}), do: %{data: Enum.map(keys, &entity/1)}

  @doc """
  `POST /v1/api_keys` 201 payload — the only response that includes
  the raw secret. The caller must persist `raw_key` immediately;
  the server never returns it again.
  """
  def created(%{key: %APIKey{} = key, raw_key: raw_key}) when is_binary(raw_key) do
    %{
      data: entity(key),
      raw_key: raw_key
    }
  end

  @doc "`DELETE /v1/api_keys/:id` payload."
  def revoked(%{key: %APIKey{} = key}), do: %{data: entity(key)}

  @doc "Single API key entity. Hard-coded allowlist — no secret leaks."
  def entity(%APIKey{} = key) do
    %{
      id: key.id,
      prefix: key.prefix,
      role: Atom.to_string(key.role),
      name: key.name,
      created_by_user_id: key.created_by_user_id,
      created_at: key.inserted_at,
      expires_at: key.expires_at,
      revoked_at: key.revoked_at
    }
  end
end
