defmodule Bank.Accounts do
  @moduledoc """
  Accounts bounded context — identity-only.

  Owns the `users` table and the read/write surface around it. Pairs
  with `Bank.Accounts.OAuthProvider` (the verify boundary that turns
  a Google authorization code into identity claims) and
  `BankWeb.AuthController` (the HTTP surface).

  Workspace membership and roles live in `Bank.Workspaces` (issue
  #155). This context is intentionally narrow: it answers "who is
  this person?" and nothing more.

  ## OAuth secret hygiene

  Functions in this module never accept or store OAuth tokens
  (access / refresh / id). The verify boundary is the place that
  briefly holds them in memory; once identity claims are extracted
  the tokens are dropped.

  ## Public surface

      get_user(id)
      get_user_by_provider_subject(provider, subject)
      find_or_create_from_oauth(claims)
      disable_user(user)
      reactivate_user(user)
  """

  alias Bank.Accounts.User
  alias Bank.Repo

  require Logger

  @type uuid :: String.t()
  @type oauth_claims :: %{
          required(:provider) => atom(),
          required(:subject) => String.t(),
          required(:email) => String.t(),
          optional(:name) => String.t() | nil,
          optional(:avatar_url) => String.t() | nil
        }

  @doc """
  Look up a user by id. Returns the struct or `nil`.
  """
  @spec get_user(uuid()) :: User.t() | nil
  def get_user(id) when is_binary(id), do: Repo.get(User, id)
  def get_user(_), do: nil

  @doc """
  Look up a user by `(provider, provider_subject)` — the canonical
  OAuth identity tuple. Returns the struct or `nil`.
  """
  @spec get_user_by_provider_subject(atom(), String.t()) :: User.t() | nil
  def get_user_by_provider_subject(provider, subject)
      when is_atom(provider) and is_binary(subject) do
    Repo.get_by(User, provider: provider, provider_subject: subject)
  end

  @doc """
  Idempotent OAuth identity write. Given verified claims:

    * if a user with `(provider, provider_subject)` exists, refresh
      the per-login fields (`name`, `avatar_url`, `last_login_at`)
      and return them. Identity columns and `status` are preserved
      so a returning login cannot accidentally promote a
      `:disabled` user.
    * otherwise insert a new user in `:pending_access`.

  Email is normalised (lowercased + trimmed) at this boundary so the
  DB's lower-email unique index is consistent regardless of how the
  provider serialised the address.

  Returns `{:ok, %User{}}` on success or `{:error, %Ecto.Changeset{}}`
  on a validation/constraint failure (e.g., a malformed email or a
  forbidden token-like field in `claims`).

  Disabled users still return `{:ok, %User{status: :disabled}}` —
  this function is identity-only; the caller (auth controller)
  decides whether to start a session.
  """
  @spec find_or_create_from_oauth(oauth_claims()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create_from_oauth(%{provider: provider, subject: subject} = claims)
      when is_atom(provider) and is_binary(subject) do
    case validate_claims_hygiene(claims) do
      :ok ->
        now = DateTime.utc_now()
        base_attrs = build_attrs(claims, now)

        case get_user_by_provider_subject(provider, subject) do
          nil ->
            %User{}
            |> User.registration_changeset(base_attrs)
            |> Repo.insert()

          %User{} = user ->
            user
            |> User.login_refresh_changeset(
              Map.take(base_attrs, [:name, :avatar_url, :last_login_at])
            )
            |> Repo.update()
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Defense in depth: refuse a claims map that carries token-shaped
  # keys at the context boundary, before they can be silently dropped
  # by `build_attrs/2`. The `Bank.Accounts.User` registration
  # changeset enforces the same rule a layer down.
  @forbidden_claim_keys ~w(
    access_token refresh_token id_token raw_response token
    authorization auth_code code state
  )a

  defp validate_claims_hygiene(claims) when is_map(claims) do
    forbidden =
      claims
      |> Map.keys()
      |> Enum.map(&claim_key_string/1)
      |> Enum.filter(&token_like_claim_key?/1)

    case forbidden do
      [] ->
        :ok

      keys ->
        changeset =
          %User{}
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.add_error(
            :base,
            "forbidden token-like field in oauth claims: #{Enum.join(keys, ", ")}"
          )

        {:error, changeset}
    end
  end

  defp claim_key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp claim_key_string(key) when is_binary(key), do: key
  defp claim_key_string(_), do: ""

  defp token_like_claim_key?(key) when is_binary(key) do
    Enum.any?(@forbidden_claim_keys, fn forbidden -> key == Atom.to_string(forbidden) end)
  end

  defp token_like_claim_key?(_), do: false

  @doc "Operator action: flip a user to `:disabled`."
  @spec disable_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def disable_user(%User{} = user) do
    user |> User.status_changeset(:disabled) |> Repo.update()
  end

  @doc "Operator action: lift a `:disabled` user back to `:pending_access`."
  @spec reactivate_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def reactivate_user(%User{} = user) do
    user |> User.status_changeset(:pending_access) |> Repo.update()
  end

  @doc """
  True iff this user can start a browser session today. `:disabled`
  users cannot. `:pending_access` users **can** start a session —
  they just land on the pending-access screen (issue #157) until
  workspace approval. `:active` users land in the app.
  """
  @spec session_allowed?(User.t()) :: boolean()
  def session_allowed?(%User{status: :disabled}), do: false
  def session_allowed?(%User{}), do: true

  defp build_attrs(claims, now) do
    %{
      provider: claims.provider,
      provider_subject: claims.subject,
      email: normalise_email(Map.get(claims, :email, "")),
      name: Map.get(claims, :name),
      avatar_url: Map.get(claims, :avatar_url),
      last_login_at: now
    }
  end

  @doc false
  # Public so OAuthProvider implementations can normalize before
  # callers inject claims, but treated as an internal contract.
  @spec normalise_email(String.t() | nil) :: String.t()
  def normalise_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  def normalise_email(_), do: ""
end
