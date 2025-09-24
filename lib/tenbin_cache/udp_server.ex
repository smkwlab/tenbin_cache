defmodule TenbinCache.UDPServer do
  @moduledoc """
  UDP server GenServer for handling DNS requests in the TenbinCache DNS proxy server.

  This module implements a high-performance UDP server that listens for incoming
  DNS queries and delegates processing to worker processes. It supports both
  IPv4 and IPv6 protocols and is designed for concurrent handling of multiple
  DNS requests with transparent packet forwarding.

  ## Architecture

  The UDPServer operates as a GenServer that:

  1. **Opens UDP socket** on the specified port for the given address family
  2. **Listens continuously** for incoming DNS packets in a blocking receive loop
  3. **Spawns worker tasks** for each DNS request using Task.Supervisor
  4. **Handles errors gracefully** with automatic recovery and logging
  5. **Manages socket lifecycle** including proper cleanup on termination

  ## Protocol Support

  - **IPv4**: Listens on `:inet` family sockets
  - **IPv6**: Listens on `:inet6` family sockets
  - **Dual-stack**: Multiple UDPServer instances can run simultaneously

  ## Concurrency Model

  The server uses a single-threaded receiver loop that immediately delegates
  DNS request processing to supervised worker tasks:

  ```
  UDPServer (GenServer)
    ↓ receives UDP packet
  Task.Supervisor
    ↓ spawns
  DNSWorker (Task)
    ↓ forwards to upstream and responds
  ```

  This design ensures that:
  - The UDP receiver never blocks on DNS processing
  - Multiple requests are handled concurrently
  - Worker failures don't affect the main server
  - Backpressure is naturally handled by the task supervisor

  ## Configuration

  Server instances are started with specific configuration:

  ```elixir
  # IPv4 server
  {:ok, pid} = TenbinCache.UDPServer.start_link(
    address_family: :inet,
    port: 53
  )
  ```

  ## Packet Processing

  Unlike tenbin_ex, this server focuses on transparent packet forwarding:
  - Preserves original DNS packet structure
  - Minimal packet inspection (only for routing)
  - Direct upstream forwarding with ID preservation
  """

  use GenServer
  require Logger

  @socket_options [
    :binary,
    {:active, false},
    {:reuseaddr, true},
    {:buffer, 65_535}
  ]

  defstruct [:socket, :address_family, :port, :packet_dump_config]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def get_port(pid) do
    GenServer.call(pid, :get_port)
  end

  @doc """
  Get the socket from the UDP server for testing purposes.

  This function provides access to the server's socket for test scenarios
  that require socket manipulation, replacing direct state introspection.
  """
  def get_socket(pid) do
    GenServer.call(pid, :get_socket)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    address_family = Keyword.fetch!(opts, :address_family)
    # 0 means allocate any available port
    port = Keyword.get(opts, :port, 0)

    # Get packet dump configuration
    server_config = TenbinCache.ConfigParser.get_server_config()

    packet_dump_config =
      if Map.get(server_config, "packet_dump", false) do
        Map.get(server_config, "dump_dir", "log/dump")
      else
        false
      end

    case open_socket(address_family, port) do
      {:ok, socket} ->
        # Get the actual assigned port (important for dynamic allocation)
        {:ok, actual_port} = :inet.port(socket)

        state = %__MODULE__{
          socket: socket,
          address_family: address_family,
          port: actual_port,
          packet_dump_config: packet_dump_config
        }

        Logger.info("UDP server started on #{address_family} port #{actual_port}")

        # Start the receive loop as a separate task to avoid blocking GenServer calls
        Task.start(fn -> receive_loop(socket, state.packet_dump_config) end)

        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to start UDP server: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_port, _from, state) do
    {:reply, {:ok, state.port}, state}
  end

  @impl true
  def handle_call(:get_socket, _from, state) do
    {:reply, {:ok, state.socket}, state}
  end

  @impl true
  def handle_info({:task_exit, reason}, state) do
    Logger.error("UDP receive task exited: #{inspect(reason)}")
    # Restart the receive loop
    Task.start(fn -> receive_loop(state.socket, state.packet_dump_config) end)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket do
      :gen_udp.close(state.socket)
    end

    :ok
  end

  # Private functions

  defp open_socket(address_family, port) do
    socket_opts = [address_family | @socket_options]
    :gen_udp.open(port, socket_opts)
  end

  defp receive_loop(socket, packet_dump_config) do
    case :gen_udp.recv(socket, 65_535) do
      {:ok, {host, port, packet}} ->
        # Spawn worker task to handle DNS query
        Task.Supervisor.start_child(
          TenbinCache.TaskSupervisor,
          fn -> TenbinCache.DNSWorker.worker({host, port, packet}, socket, packet_dump_config) end
        )

        # Continue receiving
        receive_loop(socket, packet_dump_config)

      {:error, :closed} ->
        Logger.warning("UDP socket closed in receive loop")
        :ok

      {:error, reason} ->
        Logger.error("UDP receive error: #{inspect(reason)}")
        # Small delay before retrying to avoid busy loop
        Process.sleep(100)
        receive_loop(socket, packet_dump_config)
    end
  end
end
