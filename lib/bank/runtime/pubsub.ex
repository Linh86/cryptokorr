defmodule Bank.Runtime.PubSub do
  @moduledoc """
  Typed PubSub topic helpers for the runtime realtime contract.

  The runtime-flow doc defines a small, fixed set of topics. This module
  is the single place that knows how to name them, so controllers,
  LiveViews, and workers never hand-roll strings.
  """

  @pubsub Bank.PubSub

  @type topic :: String.t()

  @doc "Per-intent lifecycle topic."
  @spec intent(binary()) :: topic()
  def intent(intent_id) when is_binary(intent_id), do: "intent:" <> intent_id

  @doc "Approval queue topic — every queued / resolved approval fans out here."
  @spec approval_queue() :: topic()
  def approval_queue, do: "approval:queue"

  @doc "Runtime status dashboard topic — pause / resume / health transitions."
  @spec dashboard_runtime_status() :: topic()
  def dashboard_runtime_status, do: "dashboard:runtime_status"

  @doc "Security events topic — pause, resume, revoke."
  @spec security_events() :: topic()
  def security_events, do: "security:events"

  @doc "Audit event stream topic — tail of every emitted audit event."
  @spec audit_stream() :: topic()
  def audit_stream, do: "audit:stream"

  @doc "Subscribe the calling process to a topic."
  @spec subscribe(topic()) :: :ok | {:error, term()}
  def subscribe(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)

  @doc "Broadcast a message to every subscriber of a topic."
  @spec broadcast(topic(), term()) :: :ok | {:error, term()}
  def broadcast(topic, message), do: Phoenix.PubSub.broadcast(@pubsub, topic, message)
end
