defmodule Bank.Telegram.Commands do
  @moduledoc """
  Inbound read-only Telegram command surface (issue #71, epic #54).

  The MVP commands are deliberately small and read-only:

    * `/help`   — list supported commands with a one-line blurb each.
    * `/status` — concise runtime-pause snapshot pulled from
      `Bank.Security.snapshot/0`. Answers *"is the runtime paused,
      and where?"* — the core operator question during an incident.
    * `/queue` — concise pending-approval summary pulled from
      `Bank.Decisions.list_pending_approvals/0`. Reuses the same
      projection the approval queue API renders from.

  ## Boundaries this module respects

    * Parsing lives in pure `parse/1` — no IO, no side effects.
    * `handle/2` reads from **existing source-of-truth helpers
      only** (`Bank.Security`, `Bank.Decisions`). It never creates
      Telegram-specific state.
    * `handle/2` gates every command on
      `Bank.Telegram.Config.can?(op, :read)` — every role in the
      #70 identity truth table currently grants `:read`, but the
      check keeps the authorization model centralised so a future
      role restriction flows through automatically.
    * No mutating command is handled here. `/pause` and `/resume`
      are intercepted by `Bank.Telegram.SecurityControls` in #73 so
      they can render explicit step-up confirmation buttons before any
      state change. Unknown commands resolve to the `/help` text —
      matching the #71 "return a safe and clear help response" rule —
      so no command text accidentally falls through into business code.

  ## Telegram group-chat suffix

  Telegram group chats often address commands to a specific bot as
  `/status@BotName`. `#71` does not yet have a configured bot
  username to compare against, so the safe choice is to ignore any
  slash command carrying an `@suffix` rather than risk responding to
  a command meant for a different bot in a shared group chat. DM
  commands and unsuffixed group commands still parse normally.

  ## Scope

  `#71` wires this module to the webhook controller and nothing
      else. Approve / reject (#72), pause / resume (#73), and
      observability / runbook (#74) are implemented in sibling modules
      rather than inside this read-only renderer.
  """

  alias Bank.Decisions
  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Security
  alias Bank.Telegram.Config
  alias Bank.Telegram.Operator

  @known %{"help" => :help, "status" => :status, "queue" => :queue}

  # Keep /queue terse. Telegram's plain-text limit is 4096; we cap
  # line count so an unexpectedly large queue still fits and stays
  # operator-readable. Callers wanting the full list follow the
  # deep link to the web console's /queue view.
  @queue_display_limit 10

  @type command_name :: :help | :status | :queue
  @type parsed ::
          {:command, command_name(), String.t()}
          | {:unknown, String.t()}
          | :not_a_command

  @doc """
  Parse the raw text of a Telegram message into a command tuple.

    * `{:command, name, args}` — a recognised command; `args` is
      the text after the command name, trimmed (may be empty).
    * `{:unknown, raw_name}` — text starts with `/` but the
      command is not in the known set. `handle/2` returns the
      help text for this case.
    * `:not_a_command` — plain text with no leading `/`. The
      caller leaves the message alone so Telegram does not mistake
      it for a reply.

  Slash commands carrying an `@suffix` are treated as `:not_a_command`
  until the bot has an authoritative username to compare against.
  """
  @spec parse(term()) :: parsed()
  def parse(text) when is_binary(text) do
    case String.trim(text) do
      "/" <> rest -> parse_slash(rest)
      _ -> :not_a_command
    end
  end

  def parse(_), do: :not_a_command

  defp parse_slash(rest) do
    {raw_name, args} =
      case String.split(rest, " ", parts: 2) do
        [head, tail] -> {head, String.trim(tail)}
        [head] -> {head, ""}
      end

    case String.split(raw_name, "@", parts: 2) do
      [_name, _bot] ->
        :not_a_command

      [name] ->
        lowered = String.downcase(name)

        case Map.fetch(@known, lowered) do
          {:ok, cmd} -> {:command, cmd, args}
          :error -> {:unknown, lowered}
        end
    end
  end

  @doc """
  Render a parsed command to the reply text the bot should send.

  Runs only after the caller has authorized the operator via
  `Bank.Telegram.Config.authorize/2`; this function additionally
  gates on `Config.can?(op, :read)` so the #70 role boundary is
  the single authorization truth. Unknown commands resolve to the
  same help text as `/help` — no state is read, no mutation is
  possible.
  """
  @spec handle(parsed(), Operator.t()) :: {:ok, String.t()}
  def handle(parsed, %Operator{} = op) do
    if Config.can?(op, :read) do
      {:ok, render_for(parsed)}
    else
      {:ok, unauthorized_text()}
    end
  end

  # --- command bodies ---

  defp render_for({:command, :help, _args}), do: help_text()

  defp render_for({:command, :status, _args}), do: status_text(Security.snapshot())

  defp render_for({:command, :queue, _args}),
    do: queue_text(Decisions.list_pending_approvals())

  defp render_for({:unknown, name}) do
    "Unknown command: /" <> name <> "\n\n" <> help_text()
  end

  defp render_for(:not_a_command), do: help_text()

  # --- /help ---

  defp help_text do
    """
    Commands:
    /help — list supported commands
    /status — current runtime pause state
    /queue — pending approval queue
    /pause — request step-up confirmation for global pause
    /resume — request step-up confirmation for global resume
    """
    |> String.trim_trailing()
  end

  defp unauthorized_text do
    "Your role does not currently allow read commands."
  end

  # --- /status ---

  defp status_text(%{global: global, counterparties: cps}) do
    global_line =
      case global do
        nil -> "Global: running"
        %{reason: reason} -> "Global: paused (#{format_reason(reason)})"
      end

    cp_line =
      case map_size(cps) do
        0 -> "Counterparty pauses: none"
        n when n <= 5 -> "Counterparty pauses: " <> Enum.join(Enum.sort(Map.keys(cps)), ", ")
        n -> "Counterparty pauses: #{n}"
      end

    lines = [
      "Runtime status",
      global_line,
      cp_line,
      "Security console: " <> web_url("/security")
    ]

    Enum.join(lines, "\n")
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(other), do: inspect(other)

  # --- /queue ---

  defp queue_text([]) do
    """
    Pending approvals: 0
    Queue: #{web_url("/queue")}
    """
    |> String.trim_trailing()
  end

  defp queue_text(decisions) when is_list(decisions) do
    total = length(decisions)
    shown = Enum.take(decisions, @queue_display_limit)

    entry_lines = Enum.map(shown, &queue_entry/1)

    overflow =
      if total > @queue_display_limit do
        ["+#{total - @queue_display_limit} more in the web console."]
      else
        []
      end

    lines =
      ["Pending approvals: #{total}" | entry_lines] ++
        overflow ++
        ["Queue: " <> web_url("/queue")]

    Enum.join(lines, "\n")
  end

  defp queue_entry(%DecisionEnvelope{} = d) do
    parts = [
      "- " <> short_id(d.id),
      "intent=" <> short_id(d.intent_id),
      "risk=" <> risk_or_dash(d.risk_tier),
      "expires=" <> expires_or_dash(d.approval_expires_at)
    ]

    Enum.join(parts, " ")
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: "?"

  defp risk_or_dash(nil), do: "-"
  defp risk_or_dash(tier) when is_binary(tier), do: tier
  defp risk_or_dash(tier) when is_atom(tier), do: Atom.to_string(tier)
  defp risk_or_dash(other), do: inspect(other)

  defp expires_or_dash(nil), do: "-"
  defp expires_or_dash(%DateTime{} = ts), do: DateTime.to_iso8601(ts)
  defp expires_or_dash(ts) when is_binary(ts), do: ts
  defp expires_or_dash(other), do: inspect(other)

  # --- url ---

  defp web_url(path) do
    try do
      BankWeb.Endpoint.url() <> path
    rescue
      _ -> path
    end
  end
end
