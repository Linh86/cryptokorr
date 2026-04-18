defmodule Bank.Telegram.Operator do
  @moduledoc """
  Authorized Telegram operator identity.

  An `Operator` is the internal representation of a Telegram actor that
  has passed `Bank.Telegram.Config.authorize/2`. Every Telegram feature
  above the config boundary consumes `Operator` structs instead of raw
  Telegram ids so audit, role checks, and logging have one consistent
  shape.

    * `user_id` — the numeric `update.from.id` from Telegram; the
      canonical identity key.
    * `chat_id` — the numeric chat id this operator is authorized to
      act from. A known user on an unknown chat is rejected at the
      boundary, not silently redirected.
    * `role` — one of `t:role/0`; used by `Bank.Telegram.Config.can?/2`
      to gate capability classes.
    * `audit_actor` — the string identifier that lands in the actor
      column of audit events. Must be stable across the operator's
      lifetime so audit trails join cleanly.

  Telegram usernames are intentionally NOT a field on this struct:
  usernames can be changed by the user at any time and therefore are
  not a valid trust anchor. See issue #70 for the rationale.
  """

  @enforce_keys [:user_id, :chat_id, :role, :audit_actor]
  defstruct [:user_id, :chat_id, :role, :audit_actor]

  @type role :: :viewer | :approver | :security_operator | :admin

  @type t :: %__MODULE__{
          user_id: integer(),
          chat_id: integer(),
          role: role(),
          audit_actor: String.t()
        }
end
