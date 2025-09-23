defmodule TenbinCacheTest do
  use ExUnit.Case
  doctest TenbinCache

  describe "UDP Server dynamic port allocation" do
    test "allocates available port automatically" do
      # Find an available port dynamically
      {:ok, socket} = :gen_udp.open(0, [:binary, {:active, false}])
      {:ok, port} = :inet.port(socket)
      :gen_udp.close(socket)

      # Verify the port is available and valid
      assert port > 0
      assert port < 65_536
    end

    test "multiple ports can be allocated independently" do
      # Test that multiple processes can get different ports
      ports = Enum.map(1..5, fn _ ->
        {:ok, socket} = :gen_udp.open(0, [:binary, {:active, false}])
        {:ok, port} = :inet.port(socket)
        :gen_udp.close(socket)
        port
      end)

      # All ports should be unique
      assert length(Enum.uniq(ports)) == 5
    end
  end

  test "greets the world" do
    assert TenbinCache.hello() == :world
  end
end
