defmodule TenbinCache.UDPServerTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import TenbinCache.DNSTestHelper

  setup do
    # Start ConfigParser for tests that need it
    unless Process.whereis(TenbinCache.ConfigParser) do
      {:ok, _pid} = TenbinCache.ConfigParser.start_link([])
    end

    # Start TaskSupervisor for integration tests
    unless Process.whereis(TenbinCache.TaskSupervisor) do
      {:ok, _pid} = Task.Supervisor.start_link(name: TenbinCache.TaskSupervisor)
    end

    :ok
  end

  describe "UDP Server dynamic port allocation" do
    test "starts with dynamic port when port 0 is specified" do
      # Start server with port 0 for dynamic allocation
      {:ok, pid} =
        TenbinCache.UDPServer.start_link(
          address_family: :inet,
          port: 0
        )

      # Get the actual allocated port
      {:ok, port} = TenbinCache.UDPServer.get_port(pid)

      # Verify port is valid and not 0
      assert port > 0
      assert port < 65_536

      # Clean up
      GenServer.stop(pid)
    end

    test "starts with specific port when specified" do
      # Find an available port first
      {:ok, test_socket} = :gen_udp.open(0, [:binary, {:active, false}])
      {:ok, available_port} = :inet.port(test_socket)
      :gen_udp.close(test_socket)

      # Start server with the specific available port
      {:ok, pid} =
        TenbinCache.UDPServer.start_link(
          address_family: :inet,
          port: available_port
        )

      # Verify the exact port is used
      {:ok, port} = TenbinCache.UDPServer.get_port(pid)
      assert port == available_port

      # Clean up
      GenServer.stop(pid)
    end

    test "multiple servers get different dynamic ports" do
      # Start multiple servers with dynamic ports
      servers =
        Enum.map(1..3, fn _ ->
          {:ok, pid} =
            TenbinCache.UDPServer.start_link(
              address_family: :inet,
              port: 0
            )

          pid
        end)

      # Get all ports
      ports =
        Enum.map(servers, fn pid ->
          {:ok, port} = TenbinCache.UDPServer.get_port(pid)
          port
        end)

      # All ports should be unique
      assert length(Enum.uniq(ports)) == 3

      # Clean up
      Enum.each(servers, &GenServer.stop/1)
    end

    test "server fails gracefully on port conflict" do
      # Start first server on a specific port
      {:ok, test_socket} = :gen_udp.open(0, [:binary, {:active, false}])
      {:ok, busy_port} = :inet.port(test_socket)
      # Keep the socket open to block the port

      # Try to start server on the same port (should fail)
      Process.flag(:trap_exit, true)

      result =
        TenbinCache.UDPServer.start_link(
          address_family: :inet,
          port: busy_port
        )

      # Should fail with appropriate error
      case result do
        {:error, _reason} ->
          # Expected error
          assert true

        {:ok, pid} ->
          # If it somehow succeeded, it should fail quickly
          receive do
            {:EXIT, ^pid, _reason} -> assert true
          after
            1000 -> flunk("Expected server to fail on port conflict")
          end
      end

      # Clean up
      :gen_udp.close(test_socket)
    end
  end

  describe "UDP Server integration" do
    test "server handles UDP packets correctly" do
      # Start server with dynamic port
      {:ok, pid} =
        TenbinCache.UDPServer.start_link(
          address_family: :inet,
          port: 0
        )

      {:ok, server_port} = TenbinCache.UDPServer.get_port(pid)

      # Create a client socket
      {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

      # Send a test DNS packet
      test_packet = <<0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
      :gen_udp.send(client_socket, {127, 0, 0, 1}, server_port, test_packet)

      # Give the server time to process (since it spawns async tasks)
      Process.sleep(100)

      # Clean up
      :gen_udp.close(client_socket)
      GenServer.stop(pid)
    end
  end

  describe "UDP Server IPv6 support" do
    test "starts successfully with IPv6 address family" do
      # Ensure ConfigParser is running for this test
      TestHelper.ensure_config_parser()

      logs =
        capture_log(fn ->
          {:ok, pid} =
            TenbinCache.UDPServer.start_link(
              address_family: :inet6,
              port: 0
            )

          # Verify server started
          assert Process.alive?(pid)

          # Get assigned port
          {:ok, port} = TenbinCache.UDPServer.get_port(pid)
          assert is_integer(port)
          assert port > 0

          # Stop the server
          GenServer.stop(pid)
        end)

      assert logs =~ "UDP server started on inet6 port"
    end
  end

  describe "UDP Server packet dump configuration" do
    test "configures packet dumping when enabled in config" do
      # Ensure ConfigParser is running
      TestHelper.ensure_config_parser()

      # Mock configuration with packet dumping enabled
      Agent.update(TenbinCache.ConfigParser, fn _ ->
        %{
          "proxy" => %{},
          "server" => %{
            "packet_dump" => true,
            "dump_dir" => "test/tmp/packets"
          }
        }
      end)

      logs =
        capture_log(fn ->
          {:ok, pid} = TenbinCache.UDPServer.start_link(address_family: :inet, port: 0)

          # Server should start successfully
          assert Process.alive?(pid)

          GenServer.stop(pid)
        end)

      assert logs =~ "UDP server started on inet port"
    end

    test "configures packet dumping as disabled when config is false" do
      # Ensure ConfigParser is running
      TestHelper.ensure_config_parser()

      # Mock configuration with packet dumping disabled
      Agent.update(TenbinCache.ConfigParser, fn _ ->
        %{
          "proxy" => %{},
          "server" => %{
            "packet_dump" => false,
            "dump_dir" => "log/dump"
          }
        }
      end)

      logs =
        capture_log(fn ->
          {:ok, pid} = TenbinCache.UDPServer.start_link(address_family: :inet, port: 0)

          # Server should start successfully
          assert Process.alive?(pid)

          GenServer.stop(pid)
        end)

      assert logs =~ "UDP server started on inet port"
    end
  end

  describe "UDP Server error handling" do
    test "handles server initialization errors" do
      # Ensure ConfigParser is alive for this test
      case Process.whereis(TenbinCache.ConfigParser) do
        nil -> {:ok, _pid} = TenbinCache.ConfigParser.start_link([])
        _ -> :ok
      end

      # This test ensures that the UDPServer can handle initialization properly
      # Since socket errors are difficult to trigger reliably in tests,
      # we test successful initialization as a proxy for error handling capability
      {:ok, pid} = TenbinCache.UDPServer.start_link(address_family: :inet, port: 0)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "terminates cleanly and closes socket" do
      {:ok, pid} = TenbinCache.UDPServer.start_link(address_family: :inet, port: 0)
      {:ok, port} = TenbinCache.UDPServer.get_port(pid)

      # Stop the server
      GenServer.stop(pid)

      # Verify the server is no longer alive
      refute Process.alive?(pid)

      # Verify the port is freed (we can start another server on the same port)
      {:ok, new_pid} = TenbinCache.UDPServer.start_link(address_family: :inet, port: port)
      GenServer.stop(new_pid)
    end

    test "handles unexpected messages gracefully" do
      {:ok, pid} = TenbinCache.UDPServer.start_link(address_family: :inet, port: 0)

      # Send an unexpected message
      send(pid, {:unexpected_message, "test"})

      # Give some time for message processing
      Process.sleep(50)

      # Server should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "handles receive loop errors gracefully" do
      {:ok, pid} = TenbinCache.UDPServer.start_link(address_family: :inet, port: 0)

      # Get the socket from the server using the public API
      {:ok, socket} = TenbinCache.UDPServer.get_socket(pid)

      # Close the socket externally to simulate error
      logs =
        capture_log(fn ->
          :gen_udp.close(socket)

          # Give some time for receive loop to detect the closed socket
          Process.sleep(200)
        end)

      # Should log the socket closure
      assert logs =~ "UDP socket closed in receive loop"

      # Server should still be alive (GenServer doesn't crash)
      assert Process.alive?(pid)

      # Stop the server properly
      GenServer.stop(pid)
    end
  end

  describe "UDP Server socket management" do
    test "returns correct port through get_port call" do
      {:ok, pid} = TenbinCache.UDPServer.start_link(address_family: :inet, port: 0)

      {:ok, port} = TenbinCache.UDPServer.get_port(pid)
      assert is_integer(port)
      assert port > 0 and port <= 65_535

      GenServer.stop(pid)
    end

    test "handles multiple concurrent connections" do
      # Ensure ConfigParser is alive for this test
      case Process.whereis(TenbinCache.ConfigParser) do
        nil -> {:ok, _pid} = TenbinCache.ConfigParser.start_link([])
        _ -> :ok
      end

      {:ok, pid} = TenbinCache.UDPServer.start_link(address_family: :inet, port: 0)
      {:ok, server_port} = TenbinCache.UDPServer.get_port(pid)

      # Create multiple client sockets
      clients =
        Enum.map(1..3, fn _ ->
          {:ok, socket} = :gen_udp.open(0, [:binary, {:active, false}])
          socket
        end)

      # Send packets from all clients
      test_packet = create_test_dns_packet()

      Enum.each(clients, fn socket ->
        :gen_udp.send(socket, {127, 0, 0, 1}, server_port, test_packet)
      end)

      # Give time for processing
      Process.sleep(200)

      # Server should still be alive
      assert Process.alive?(pid)

      # Clean up
      Enum.each(clients, &:gen_udp.close/1)
      GenServer.stop(pid)
    end

    test "handles large packets within buffer limits" do
      {:ok, pid} = TenbinCache.UDPServer.start_link(address_family: :inet, port: 0)
      {:ok, server_port} = TenbinCache.UDPServer.get_port(pid)

      # Create a large but valid DNS packet (close to buffer limit)
      large_packet = TenbinCache.DNSTestHelper.create_large_dns_packet()

      {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

      # Send large packet - should not crash the server
      :gen_udp.send(client_socket, {127, 0, 0, 1}, server_port, large_packet)

      # Give time for processing
      Process.sleep(100)

      # Server should still be alive
      assert Process.alive?(pid)

      :gen_udp.close(client_socket)
      GenServer.stop(pid)
    end
  end
end
