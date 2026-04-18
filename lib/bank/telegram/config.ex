defmodule Bank.Telegram.Config do
  @moduledoc """
  Identity, allowlist, role, and secrets boundary for the Telegram
  operator bot (epic #54, issue #70).

  Every Telegram feature above this module depends on one deterministic,
  fail-closed trust boundary:

    * the bot token lives only in `TELEGRAM_BOT_TOKEN` (env);
    * operators are an explicit, reviewable allowlist of
      `(user_id, chat_id)` tuples plus a role;
    * unknown senders, disabled environments, mismatched chats, and
      missing tokens all return distinct `{:error, reason}` atoms;
    * Telegram usernames are never consulted — only numeric ids.

  ## Config shape

      config :bank, Bank.Telegram.Config,
        enabled: boolean(),
        bot_token: String.t() | nil,
        operators: [
          %{
            user_id: integer(),
            chat_id: integer(),
            role: Bank.Telegram.Operator.role(),
            audit_actor: String.t()
          }
        ]

  Production supplies these via `TELEGRAM_BOT_ENABLED`,
  `TELEGRAM_BOT_TOKEN`, and `TELEGRAM_OPERATORS` in `config/runtime.exs`.
  The bot is disabled by default in dev and test; tests opt in by
  calling `Application.put_env/3` under `async: false`.

  ## Roles

    * `:viewer` — read-only commands (`/status`, `/queue`, `/help`).
    * `:approver` — viewer + approve / reject on the queue.
    * `:security_operator` — approver + pause / resume of the runtime.
    * `:admin` — every listed capability.

  Role → action is a static truth table; there is no default-allow and
  unknown actions raise rather than silently falling through.

  ## Why this file exists alone

  The scope of issue #70 is the trust boundary; higher-level surfaces
  (transport, webhook, callback tokens, alert templates, approval
  flows) land in subsequent issues of epic #54 and must consume this
  module rather than parsing env vars or user ids themselves.
  """

  alias Bank.Telegram.Operator

  @roles ~w(viewer approver security_operator admin)a
  @actions ~w(read approve_reject pause_resume)a

  @type config :: %{
          enabled: boolean(),
          bot_token: String.t() | nil,
          operators: [Operator.t()]
        }

  @type auth_error ::
          :bot_disabled
          | :bot_not_configured
          | :unknown_user
          | :chat_mismatch
          | :invalid_config

  @type token_error :: :bot_disabled | :bot_not_configured | :invalid_config

  @doc """
  Load and validate the Telegram bot configuration from application
  env.

  Returns `{:ok, cfg}` on a valid shape, or `{:error, reason}` when an
  operator record is malformed. Callers above the boundary should go
  through `authorize/2` and `bot_token/0` instead of interpreting this
  directly.
  """
  @spec load() :: {:ok, config()} | {:error, term()}
  def load do
    raw = Application.get_env(:bank, __MODULE__, [])
    enabled = Keyword.get(raw, :enabled, false) == true
    bot_token = Keyword.get(raw, :bot_token)

    case parse_operators(Keyword.get(raw, :operators, [])) do
      {:ok, operators} ->
        {:ok, %{enabled: enabled, bot_token: bot_token, operators: operators}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  True when the bot is enabled AND the config shape is valid.

  A broken config shape is treated as disabled here so that code paths
  guarded by `enabled?/0` fail closed without raising.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case load() do
      {:ok, %{enabled: enabled}} -> enabled
      _ -> false
    end
  end

  @doc """
  Return the configured bot token, or a fail-closed error.

  Callers above the boundary (the transport in issue #69) must not read
  `TELEGRAM_BOT_TOKEN` directly — they get the token through this
  function so enable/disable and shape errors route uniformly.
  """
  @spec bot_token() :: {:ok, String.t()} | {:error, token_error()}
  def bot_token do
    case load() do
      {:ok, %{enabled: false}} -> {:error, :bot_disabled}
      {:ok, %{bot_token: token}} when is_binary(token) and byte_size(token) > 0 -> {:ok, token}
      {:ok, _} -> {:error, :bot_not_configured}
      {:error, _} -> {:error, :invalid_config}
    end
  end

  @doc """
  Authorize a Telegram actor identified by numeric user and chat id.

  Returns `{:ok, operator}` when the tuple is in the allowlist and the
  bot is enabled and configured. Otherwise returns a specific
  `{:error, reason}` so higher layers can route each failure (ignore,
  log, alert) distinctly.

  The function is guarded on integer ids — the API has no username
  path. Transport-layer code must resolve Telegram `update.from.id` and
  `chat.id` into integers before calling this function; a string
  username will raise `FunctionClauseError`, which is deliberate.
  """
  @spec authorize(integer(), integer()) :: {:ok, Operator.t()} | {:error, auth_error()}
  def authorize(user_id, chat_id) when is_integer(user_id) and is_integer(chat_id) do
    case load() do
      {:ok, cfg} ->
        cond do
          not cfg.enabled -> {:error, :bot_disabled}
          cfg.bot_token in [nil, ""] -> {:error, :bot_not_configured}
          true -> find_operator(cfg.operators, user_id, chat_id)
        end

      {:error, _} ->
        {:error, :invalid_config}
    end
  end

  @doc """
  Static role-to-action capability check.

  Returns `true` when the operator's role grants the requested action,
  `false` otherwise. Unknown actions raise `FunctionClauseError` so
  callers cannot silently accept a typo.
  """
  @spec can?(Operator.t(), atom()) :: boolean()
  def can?(%Operator{role: role}, action) when action in @actions do
    allow?(role, action)
  end

  @doc "Valid role atoms. Used by the env-var parser and tests."
  @spec roles() :: [Operator.role()]
  def roles, do: @roles

  @doc "Valid action atoms for `can?/2`. Used by tests."
  @spec actions() :: [atom()]
  def actions, do: @actions

  @doc """
  Parse the `TELEGRAM_OPERATORS` env-var format into a list of operator
  records suitable for `config :bank, Bank.Telegram.Config, operators: ...`.

  Format: pipe-separated records, each record colon-separated:

      USER_ID:CHAT_ID:ROLE:AUDIT_ACTOR

  `USER_ID` and `CHAT_ID` are integers (chat ids can be negative for
  groups and channels). `ROLE` must be one of `roles/0`. `AUDIT_ACTOR`
  is a non-empty string used as the audit attribution label.

  Called from `config/runtime.exs`. Raises `ArgumentError` on any
  malformed record so a production boot fails loudly rather than
  silently shipping a half-populated allowlist.
  """
  @spec parse_operators_env!(String.t()) :: [map()]
  def parse_operators_env!(""), do: []

  def parse_operators_env!(raw) when is_binary(raw) do
    raw
    |> String.split("|", trim: true)
    |> Enum.with_index()
    |> Enum.map(fn {record, idx} -> parse_env_record!(record, idx) end)
  end

  # --- internals ---

  defp parse_env_record!(record, idx) do
    case String.split(record, ":", parts: 4) do
      [user_id_s, chat_id_s, role_s, audit_actor] when audit_actor != "" ->
        %{
          user_id: parse_int!(user_id_s, idx, :user_id),
          chat_id: parse_int!(chat_id_s, idx, :chat_id),
          role: parse_role!(role_s, idx),
          audit_actor: audit_actor
        }

      _ ->
        raise ArgumentError,
              "TELEGRAM_OPERATORS record #{idx} is malformed — expected " <>
                "USER_ID:CHAT_ID:ROLE:AUDIT_ACTOR with a non-empty audit actor, " <>
                "got: #{inspect(record)}"
    end
  end

  defp parse_int!(s, idx, field) do
    case Integer.parse(s) do
      {int, ""} ->
        int

      _ ->
        raise ArgumentError,
              "TELEGRAM_OPERATORS record #{idx} field #{field} must be an integer, " <>
                "got: #{inspect(s)}"
    end
  end

  defp parse_role!(s, idx) do
    role =
      try do
        String.to_existing_atom(s)
      rescue
        ArgumentError -> :__unknown__
      end

    if role in @roles do
      role
    else
      raise ArgumentError,
            "TELEGRAM_OPERATORS record #{idx} has unknown role #{inspect(s)}; " <>
              "valid: #{inspect(@roles)}"
    end
  end

  defp parse_operators(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, idx}, {:ok, acc} ->
      case parse_operator(entry) do
        {:ok, op} -> {:cont, {:ok, [op | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_operator, idx, reason}}}
      end
    end)
    |> case do
      {:ok, ops} -> {:ok, Enum.reverse(ops)}
      other -> other
    end
  end

  defp parse_operators(_other), do: {:error, :operators_not_a_list}

  defp parse_operator(%{
         user_id: user_id,
         chat_id: chat_id,
         role: role,
         audit_actor: actor
       })
       when is_integer(user_id) and is_integer(chat_id) and is_binary(actor) do
    cond do
      actor == "" -> {:error, :blank_audit_actor}
      role not in @roles -> {:error, {:unknown_role, role}}
      true -> {:ok, %Operator{user_id: user_id, chat_id: chat_id, role: role, audit_actor: actor}}
    end
  end

  defp parse_operator(_), do: {:error, :malformed_operator}

  defp find_operator(operators, user_id, chat_id) do
    user_matches = Enum.filter(operators, &(&1.user_id == user_id))

    cond do
      user_matches == [] ->
        {:error, :unknown_user}

      op = Enum.find(user_matches, &(&1.chat_id == chat_id)) ->
        {:ok, op}

      true ->
        {:error, :chat_mismatch}
    end
  end

  defp allow?(:admin, _action), do: true
  defp allow?(:security_operator, action) when action in [:read, :approve_reject, :pause_resume], do: true
  defp allow?(:approver, action) when action in [:read, :approve_reject], do: true
  defp allow?(:viewer, :read), do: true
  defp allow?(_role, _action), do: false
end
