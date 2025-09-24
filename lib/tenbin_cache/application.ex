defmodule TenbinCache.Application do
  @moduledoc """
  Main application supervisor for TenbinCache DNS proxy server.

  Follows the same architecture as tenbin_ex but simplified for pure proxy functionality.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Configuration agent (similar to tenbin_ex ConfigParser)
      TenbinCache.ConfigParser,

      # Task supervisor for DNS workers
      {Task.Supervisor, name: TenbinCache.TaskSupervisor},

      # UDP server supervisor
      TenbinCache.UDPServerSupervisor
    ]

    opts = [strategy: :one_for_one, name: TenbinCache.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("TenbinCache DNS proxy server started")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start TenbinCache: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
