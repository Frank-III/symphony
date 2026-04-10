defmodule SymphonyElixir.Runtime.Adapter do
  @moduledoc """
  Behaviour contract for runtime adapters.

  Each adapter wraps a specific transport (direct stdio, ACP endpoint, etc.)
  and exposes a uniform session/turn lifecycle to the orchestrator.
  """

  alias SymphonyElixir.Config.Schema.RuntimeProfile

  @type session :: map()
  @type turn_result :: {:ok, map()} | {:error, term()}
  @type session_result :: {:ok, session()} | {:error, term()}

  @type runtime_metadata :: %{
          optional(:profile_name) => String.t(),
          optional(:provider) => String.t(),
          optional(:adapter) => String.t(),
          optional(:transport) => String.t() | nil,
          optional(:display_name) => String.t() | nil,
          optional(:session_id) => String.t(),
          optional(:turn_count) => non_neg_integer(),
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer(),
          optional(:last_event) => atom(),
          optional(:health) => :healthy | :degraded | :unhealthy
        }

  @doc "Start a session for the given workspace and profile."
  @callback start_session(RuntimeProfile.t(), Path.t(), keyword()) :: session_result()

  @doc "Execute a single turn within an active session."
  @callback run_turn(session(), String.t(), map(), keyword()) :: turn_result()

  @doc "Stop and clean up a session."
  @callback stop_session(session()) :: :ok

  @doc "Return normalized runtime metadata from the current session state."
  @callback runtime_metadata(session()) :: runtime_metadata()
end
