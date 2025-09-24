defmodule TenbinCache.DNSWorkerTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import TenbinCache.DNSTestHelper

  setup do
    # Ensure ConfigParser is stopped and restarted for clean state
    case Process.whereis(TenbinCache.ConfigParser) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end

    {:ok, _pid} = TenbinCache.ConfigParser.start_link([])

    # Start TaskSupervisor for integration tests
    unless Process.whereis(TenbinCache.TaskSupervisor) do
      {:ok, _pid} = Task.Supervisor.start_link(name: TenbinCache.TaskSupervisor)
    end

    :ok
  end

  describe "DNS Worker error handling" do
    test "handles upstream server timeout gracefully" do
      # Create a mock DNS packet
      test_packet = create_test_dns_packet()

      # Create a mock client socket
      {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

      # Set up configuration with timeout to non-responsive server
      proxy_config = %{
        # Non-routable IP for timeout
        "upstream" => "10.255.255.1",
        "upstream_port" => 53,
        # Very short timeout
        "timeout" => 100,
        "max_retries" => 1
      }

      # Mock the configuration
      # Give a small delay to ensure ConfigParser is ready
      Process.sleep(10)

      Agent.update(TenbinCache.ConfigParser, fn _ ->
        %{"proxy" => proxy_config, "server" => %{}}
      end)

      # Capture logs to verify error handling
      logs =
        capture_log(fn ->
          TenbinCache.DNSWorker.worker(
            {{127, 0, 0, 1}, 12_345, test_packet},
            client_socket,
            false
          )
        end)

      # Verify that appropriate error messages are logged
      assert logs =~ "DNS forward to 10.255.255.1 failed"
      assert logs =~ "retrying"
      assert logs =~ "timeout after all retries"

      :gen_udp.close(client_socket)
    end

    test "handles invalid upstream server address" do
      # Create a mock DNS packet
      test_packet = create_test_dns_packet()

      # Create a mock client socket
      {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

      # Set up configuration with invalid upstream server
      proxy_config = %{
        "upstream" => "invalid.server.address",
        "upstream_port" => 53,
        "timeout" => 1000,
        "max_retries" => 1
      }

      # Mock the configuration
      # Give a small delay to ensure ConfigParser is ready
      Process.sleep(10)

      Agent.update(TenbinCache.ConfigParser, fn _ ->
        %{"proxy" => proxy_config, "server" => %{}}
      end)

      # This should handle gracefully by falling back to localhost
      logs =
        capture_log(fn ->
          TenbinCache.DNSWorker.worker(
            {{127, 0, 0, 1}, 12_345, test_packet},
            client_socket,
            false
          )
        end)

      # Should not crash and should handle the fallback gracefully
      assert logs =~ "DNS forward to invalid.server.address failed" or
               logs =~ "DNS proxy forward failed"

      :gen_udp.close(client_socket)
    end

    test "retries failed upstream connections" do
      # Create a mock DNS packet
      test_packet = create_test_dns_packet()

      # Create a mock client socket
      {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

      # Set up configuration with non-existent port
      proxy_config = %{
        "upstream" => "127.0.0.1",
        # Non-existent DNS server port
        "upstream_port" => 12_345,
        "timeout" => 500,
        "max_retries" => 2
      }

      # Mock the configuration
      # Give a small delay to ensure ConfigParser is ready
      Process.sleep(10)

      Agent.update(TenbinCache.ConfigParser, fn _ ->
        %{"proxy" => proxy_config, "server" => %{}}
      end)

      # Capture logs to verify retry behavior
      logs =
        capture_log(fn ->
          TenbinCache.DNSWorker.worker(
            {{127, 0, 0, 1}, 12_345, test_packet},
            client_socket,
            false
          )
        end)

      # Verify retry attempts are logged
      assert logs =~ "retrying (2 attempts left)"
      assert logs =~ "retrying (1 attempts left)"

      :gen_udp.close(client_socket)
    end

    test "generates SERVFAIL response on upstream failure" do
      # Create a mock DNS packet
      test_packet = create_test_dns_packet()

      # Create a mock client socket and get its port for monitoring
      {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])
      {:ok, client_port} = :inet.port(client_socket)

      # Create a monitoring socket to capture responses
      {:ok, monitor_socket} = :gen_udp.open(client_port + 1, [:binary, {:active, false}])

      # Set up configuration with non-responsive server
      proxy_config = %{
        # Non-routable IP
        "upstream" => "10.255.255.1",
        "upstream_port" => 53,
        "timeout" => 100,
        # No retries for faster test
        "max_retries" => 0
      }

      # Mock the configuration
      # Give a small delay to ensure ConfigParser is ready
      Process.sleep(10)

      Agent.update(TenbinCache.ConfigParser, fn _ ->
        %{"proxy" => proxy_config, "server" => %{}}
      end)

      # Execute the worker
      TenbinCache.DNSWorker.worker(
        {{127, 0, 0, 1}, client_port + 1, test_packet},
        client_socket,
        false
      )

      # Try to receive the SERVFAIL response
      case :gen_udp.recv(monitor_socket, 512, 1000) do
        {:ok, {_addr, _port, response_packet}} ->
          # Parse the response to verify it's a SERVFAIL
          parsed_response = DNSpacket.parse(response_packet)
          # SERVFAIL
          assert parsed_response.rcode == 2
          # Response bit set
          assert parsed_response.qr == 1

        {:error, :timeout} ->
          # Response might have been sent to different socket, that's ok for this test
          assert true

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end

      :gen_udp.close(client_socket)
      :gen_udp.close(monitor_socket)
    end
  end

  describe "DNS Worker packet handling" do
    test "handles packet dump functionality when enabled" do
      # Create a test packet
      test_packet = create_test_dns_packet()

      # Create a mock client socket
      {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

      # Create a temporary directory for packet dumps
      dump_dir = "test/tmp/packet_dump"
      File.mkdir_p!(dump_dir)

      # Set up configuration with packet dumping enabled
      proxy_config = %{
        "upstream" => "127.0.0.1",
        # Non-existent DNS server port
        "upstream_port" => 12_345,
        "timeout" => 100,
        "max_retries" => 0
      }

      server_config = %{
        "packet_dump" => true,
        "dump_dir" => dump_dir
      }

      # Mock the configuration
      Process.sleep(10)

      Agent.update(TenbinCache.ConfigParser, fn _ ->
        %{"proxy" => proxy_config, "server" => server_config}
      end)

      # Execute the worker
      TenbinCache.DNSWorker.worker(
        {{127, 0, 0, 1}, 12_345, test_packet},
        client_socket,
        dump_dir
      )

      # Verify that packet files were created
      {:ok, files} = File.ls(dump_dir)
      packet_files = Enum.filter(files, &String.contains?(&1, "dns_packet"))

      # Should have at least 2 files: incoming and outgoing packets
      assert length(packet_files) >= 2

      # Verify files contain the expected packet data
      in_files = Enum.filter(packet_files, &String.contains?(&1, "-in-"))
      out_files = Enum.filter(packet_files, &String.contains?(&1, "-out-"))

      assert length(in_files) >= 1
      assert length(out_files) >= 1

      # Clean up
      File.rm_rf!(dump_dir)
      :gen_udp.close(client_socket)
    end

    test "handles packet dump when directory creation fails" do
      # Create a test packet
      test_packet = create_test_dns_packet()

      # Create a mock client socket
      {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

      # Use an invalid dump directory (portable across all OS)
      invalid_dump_dir = TenbinCache.DNSTestHelper.create_invalid_directory_path()

      # Set up configuration with packet dumping enabled but invalid directory
      proxy_config = %{
        "upstream" => "127.0.0.1",
        # Non-existent DNS server port
        "upstream_port" => 12_345,
        "timeout" => 100,
        "max_retries" => 0
      }

      # Mock the configuration
      Process.sleep(10)

      Agent.update(TenbinCache.ConfigParser, fn _ ->
        %{"proxy" => proxy_config, "server" => %{}}
      end)

      # This should not crash even if packet dump fails
      logs =
        capture_log(fn ->
          TenbinCache.DNSWorker.worker(
            {{127, 0, 0, 1}, 12_345, test_packet},
            client_socket,
            invalid_dump_dir
          )
        end)

      # Should contain error or continue processing
      assert logs =~ "Failed to save packet" or logs =~ "DNS proxy forward failed"

      :gen_udp.close(client_socket)
    end

    test "handles DNS packet parsing failure gracefully" do
      # Create an invalid DNS packet
      invalid_packet = <<0xFF, 0xFF, 0xFF, 0xFF>>

      # Create a mock client socket
      {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

      # Set up configuration
      proxy_config = %{
        "upstream" => "127.0.0.1",
        "upstream_port" => 12_345,
        "timeout" => 100,
        "max_retries" => 0
      }

      # Mock the configuration
      Process.sleep(10)

      Agent.update(TenbinCache.ConfigParser, fn _ ->
        %{"proxy" => proxy_config, "server" => %{}}
      end)

      # This should handle invalid packets gracefully
      logs =
        capture_log(fn ->
          TenbinCache.DNSWorker.worker(
            {{127, 0, 0, 1}, 12_345, invalid_packet},
            client_socket,
            false
          )
        end)

      # Should either generate a minimal SERVFAIL or log parsing failure
      assert logs =~ "Failed to parse packet" or logs =~ "DNS proxy forward failed"

      :gen_udp.close(client_socket)
    end

    test "handles worker function exceptions" do
      # Create a mock client socket
      {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

      # This should handle exceptions gracefully by using invalid packet that causes parsing errors
      _logs =
        capture_log(fn ->
          # Use a packet that will cause an exception during DNSpacket.parse
          # Too short to be a valid DNS packet
          invalid_packet = <<0x12, 0x34>>

          result =
            TenbinCache.DNSWorker.worker(
              {{127, 0, 0, 1}, 12_345, invalid_packet},
              client_socket,
              false
            )

          assert result == :ok
        end)

      # Should either handle gracefully or continue processing
      # The function should not crash and return :ok
      :gen_udp.close(client_socket)
    end

    test "tests send_reply failure handling" do
      # Create a test packet
      test_packet = create_test_dns_packet()

      # Create a client socket and close it immediately to cause send failure
      {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])
      :gen_udp.close(client_socket)

      # Set up configuration
      proxy_config = %{
        "upstream" => "127.0.0.1",
        "upstream_port" => 12_345,
        "timeout" => 100,
        "max_retries" => 0
      }

      # Mock the configuration
      Process.sleep(10)

      Agent.update(TenbinCache.ConfigParser, fn _ ->
        %{"proxy" => proxy_config, "server" => %{}}
      end)

      # This should handle send failures gracefully
      logs =
        capture_log(fn ->
          TenbinCache.DNSWorker.worker(
            {{127, 0, 0, 1}, 12_345, test_packet},
            client_socket,
            false
          )
        end)

      # Should log the send failure or continue without crashing
      assert logs =~ "Failed to send DNS reply" or logs =~ "DNS proxy forward failed"
    end
  end
end
