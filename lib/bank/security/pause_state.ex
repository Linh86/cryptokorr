defmodule Bank.Security.PauseState do
  @moduledoc """
  Process-local pause registry.

  Tracks the current pause state (global and per-counterparty). v0.1
  keeps this in-memory — there is exactly one control-plane node per
  deployment and the expected recovery path on crash is "re-pause if
  you were paused" via an operator action, because a safety control
  should never silently come back up in a less-restricted state.

  A persistence-backed version is a v1.0 follow-up tracked in the
  runtime-flow doc.

  ## API

      pause(:global, reason, actor_opts)
      pause({:counterparty, cp_id}, reason, actor_opts)
      resume(:global, actor_opts)
      resume({:counterparty, cp_id}, actor_opts)
      paused?(:global)
      paused?({:counterparty, cp_id})
      snapshot()

  The `pause/3` and `resume/2` functions are idempotent: pausing a
  paused scope or resuming a running one returns `:ok` without mutating
  state, so operators can double-tap safely during an incident.
  """

  use GenServer

  @type scope :: :global | {:counterparty, String.t()}
  @type reason :: atom() | String.t()
  @type pause_record :: %{
          paused_at: DateTime.t(),
          reason: reason(),
          actor: atom(),
          actor_id: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{global: nil, counterparties: %{}}, name: name)
  end

  @spec pause(scope(), reason(), keyword()) ::
          {:ok, :already_paused | :paused} | {:error, term()}
  def pause(scope, reason, actor_opts \\ []) do
    GenServer.call(__MODULE__, {:pause, scope, reason, actor_opts})
  end

  @spec resume(scope(), keyword()) ::
          {:ok, :already_running | :resumed} | {:error, term()}
  def resume(scope, actor_opts \\ []) do
    GenServer.call(__MODULE__, {:resume, scope, actor_opts})
  end

  @spec paused?(scope()) :: boolean()
  def paused?(scope) do
    GenServer.call(__MODULE__, {:paused?, scope})
  end

  @spec snapshot() :: %{
          global: pause_record() | nil,
          counterparties: %{String.t() => pause_record()}
        }
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # --- callbacks -----------------------------------------------------

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:pause, :global, reason, opts}, _from, state) do
    case state.global do
      nil ->
        record = build_record(reason, opts)
        {:reply, {:ok, :paused}, %{state | global: record}}

      _record ->
        {:reply, {:ok, :already_paused}, state}
    end
  end

  def handle_call({:pause, {:counterparty, id}, reason, opts}, _from, state) do
    case Map.get(state.counterparties, id) do
      nil ->
        record = build_record(reason, opts)
        {:reply, {:ok, :paused}, put_in(state.counterparties[id], record)}

      _record ->
        {:reply, {:ok, :already_paused}, state}
    end
  end

  def handle_call({:resume, :global, _opts}, _from, state) do
    case state.global do
      nil -> {:reply, {:ok, :already_running}, state}
      _ -> {:reply, {:ok, :resumed}, %{state | global: nil}}
    end
  end

  def handle_call({:resume, {:counterparty, id}, _opts}, _from, state) do
    case Map.pop(state.counterparties, id) do
      {nil, _} -> {:reply, {:ok, :already_running}, state}
      {_, rest} -> {:reply, {:ok, :resumed}, %{state | counterparties: rest}}
    end
  end

  def handle_call({:paused?, :global}, _from, state), do: {:reply, state.global != nil, state}

  def handle_call({:paused?, {:counterparty, id}}, _from, state) do
    paused? = state.global != nil or Map.has_key?(state.counterparties, id)
    {:reply, paused?, state}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call(:reset, _from, _state),
    do: {:reply, :ok, %{global: nil, counterparties: %{}}}

  defp build_record(reason, opts) do
    %{
      paused_at: DateTime.utc_now(),
      reason: reason,
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id)
    }
  end
end
