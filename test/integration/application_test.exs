defmodule TenbinCache.ApplicationTest do
  use ExUnit.Case

  describe "Application integration" do
    test "application starts and stops cleanly" do
      # Stop if already running
      Application.stop(:tenbin_cache)

      # Start the application
      result = Application.start(:tenbin_cache)
      assert result == :ok or match?({:ok, _pid}, result)

      # Verify the main components are running
      assert Process.whereis(TenbinCache.ConfigParser) != nil
      assert Process.whereis(TenbinCache.TaskSupervisor) != nil
      assert Process.whereis(TenbinCache.UDPServerSupervisor) != nil

      # Stop the application
      assert :ok = Application.stop(:tenbin_cache)

      # Verify components are stopped
      Process.sleep(100)  # Allow time for cleanup
      assert Process.whereis(TenbinCache.ConfigParser) == nil
    end

    test "application uses dynamic ports in test environment" do
      # Stop if already running
      Application.stop(:tenbin_cache)

      # Ensure we're in test environment
      assert Mix.env() == :test

      # Start the application
      result = Application.start(:tenbin_cache)
      assert result == :ok or match?({:ok, _pid}, result)

      # The supervisor should be running
      supervisor_pid = Process.whereis(TenbinCache.UDPServerSupervisor)
      assert supervisor_pid != nil

      # Get the UDP server children
      children = Supervisor.which_children(TenbinCache.UDPServerSupervisor)
      assert length(children) > 0

      # Verify at least one server is running
      {_id, server_pid, _type, _modules} = hd(children)
      assert is_pid(server_pid)

      # Get the port (should be dynamic, not 5353)
      {:ok, port} = TenbinCache.UDPServer.get_port(server_pid)
      assert port != 5353  # Should not be the configured port
      assert port > 0 and port < 65_536

      # Clean up
      Application.stop(:tenbin_cache)
    end
  end
end