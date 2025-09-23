defmodule TenbinCache.UDPServerSupervisor do
  @moduledoc """
  Supervisor for UDP server processes in the TenbinCache DNS proxy server.

  This supervisor manages one or more UDP server instances, typically one
  for IPv4 and optionally one for IPv6. Each server runs independently
  and handles DNS queries for its respective address family.

  ## Architecture

  ```
  UDPServerSupervisor (one_for_one)
  ├── UDPServer (IPv4)
  └── UDPServer (IPv6) [optional]
  ```

  ## Configuration

  Server configuration is read from the ConfigParser:
  - Port number for DNS server
  - Address families to bind (IPv4, IPv6, or both)
  - Packet dumping settings
  """

  use Supervisor
  require Logger

  def start_link(_) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    proxy_config = TenbinCache.ConfigParser.get_proxy_config()
    configured_port = Map.get(proxy_config, "port", 5353)

    # Use dynamic port allocation in test environment
    port = case Application.get_env(:tenbin_cache, :env, Mix.env()) do
      :test -> 0  # Dynamic port allocation for tests
      _ -> configured_port
    end

    children = [
      # IPv4 UDP server
      %{
        id: :udp_server_ipv4,
        start: {TenbinCache.UDPServer, :start_link, [[address_family: :inet, port: port]]},
        restart: :permanent,
        type: :worker
      }

      # TODO: Add IPv6 support when needed
      # %{
      #   id: :udp_server_ipv6,
      #   start: {TenbinCache.UDPServer, :start_link, [[address_family: :inet6, port: port]]},
      #   restart: :permanent,
      #   type: :worker
      # }
    ]

    if port == 0 do
      Logger.info("Starting UDP servers with dynamic port allocation (test mode)")
    else
      Logger.info("Starting UDP servers on port #{port}")
    end

    Supervisor.init(children, strategy: :one_for_one)
  end
end