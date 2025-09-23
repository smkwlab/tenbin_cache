defmodule TenbinCache.ConfigParserTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  # Use a custom config file for testing
  @test_config_dir "test/tmp/config"
  @test_config_file Path.join(@test_config_dir, "test_config.yaml")
  @invalid_config_file Path.join(@test_config_dir, "invalid_config.yaml")
  @missing_config_file Path.join(@test_config_dir, "missing_config.yaml")

  setup do
    # Stop ConfigParser if running
    case Process.whereis(TenbinCache.ConfigParser) do
      nil -> :ok
      pid when is_pid(pid) ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end

    # Create test directory
    File.mkdir_p!(@test_config_dir)

    # Clean up application environment
    Application.delete_env(:tenbin_cache, :config_file)

    # Register cleanup function
    on_exit(fn ->
      # Clean up test files and environment
      File.rm_rf!(@test_config_dir)
      Application.delete_env(:tenbin_cache, :config_file)

      # Stop ConfigParser if running
      case Process.whereis(TenbinCache.ConfigParser) do
        nil -> :ok
        pid when is_pid(pid) ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
      end
    end)

    :ok
  end

  describe "ConfigParser initialization" do
    test "starts with default configuration when no config file found" do
      # Temporarily remove existing config paths
      Application.put_env(:tenbin_cache, :config_file, @missing_config_file)

      logs = capture_log(fn ->
        {:ok, _pid} = TenbinCache.ConfigParser.start_link([])
      end)

      assert logs =~ "Custom config file not found"
      assert logs =~ "using defaults"

      # Verify default configuration is loaded
      config = TenbinCache.ConfigParser.get_all()
      assert is_map(config)
      assert Map.has_key?(config, "proxy")
      assert Map.has_key?(config, "server")

      proxy_config = TenbinCache.ConfigParser.get_proxy_config()
      assert proxy_config["port"] == 5353
      assert proxy_config["upstream"] == "8.8.8.8"
      assert proxy_config["upstream_port"] == 53
      assert proxy_config["timeout"] == 5000
      assert proxy_config["cache_enabled"] == true
      assert proxy_config["cache_ttl"] == 300

      server_config = TenbinCache.ConfigParser.get_server_config()
      assert server_config["packet_dump"] == false
      assert server_config["dump_dir"] == "log/dump"
    end

    test "loads valid YAML configuration file" do
      # Create a test config file
      test_config = """
      proxy:
        port: 1234
        upstream: "1.1.1.1"
        upstream_port: 5353
        timeout: 2000
        cache_enabled: false
        cache_ttl: 600
      server:
        packet_dump: true
        dump_dir: "custom/dump"
      """

      File.write!(@test_config_file, test_config)
      Application.put_env(:tenbin_cache, :config_file, @test_config_file)

      logs = capture_log(fn ->
        {:ok, _pid} = TenbinCache.ConfigParser.start_link([])
      end)

      assert logs =~ "Loading configuration from: #{@test_config_file}"
      assert logs =~ "Configuration loaded successfully"

      # Verify custom configuration is loaded
      proxy_config = TenbinCache.ConfigParser.get_proxy_config()
      assert proxy_config["port"] == 1234
      assert proxy_config["upstream"] == "1.1.1.1"
      assert proxy_config["upstream_port"] == 5353
      assert proxy_config["timeout"] == 2000
      assert proxy_config["cache_enabled"] == false
      assert proxy_config["cache_ttl"] == 600

      server_config = TenbinCache.ConfigParser.get_server_config()
      assert server_config["packet_dump"] == true
      assert server_config["dump_dir"] == "custom/dump"
    end

    test "handles invalid YAML configuration gracefully" do
      # Create an invalid YAML file
      invalid_yaml = """
      proxy:
        port: 1234
      [invalid yaml structure
      """

      File.write!(@invalid_config_file, invalid_yaml)
      Application.put_env(:tenbin_cache, :config_file, @invalid_config_file)

      logs = capture_log(fn ->
        {:ok, _pid} = TenbinCache.ConfigParser.start_link([])
      end)

      assert logs =~ "Loading configuration from: #{@invalid_config_file}"
      assert logs =~ "Failed to parse YAML config"

      # Should fall back to defaults
      proxy_config = TenbinCache.ConfigParser.get_proxy_config()
      assert proxy_config["port"] == 5353  # Default value
      assert proxy_config["upstream"] == "8.8.8.8"  # Default value
    end

    test "handles unreadable configuration file gracefully" do
      # Create a file and make it unreadable
      File.write!(@test_config_file, "test content")
      File.chmod!(@test_config_file, 0o000)  # Remove all permissions

      Application.put_env(:tenbin_cache, :config_file, @test_config_file)

      logs = capture_log(fn ->
        {:ok, _pid} = TenbinCache.ConfigParser.start_link([])
      end)

      assert logs =~ "Failed to read config file"

      # Should fall back to defaults
      proxy_config = TenbinCache.ConfigParser.get_proxy_config()
      assert proxy_config["port"] == 5353  # Default value

      # Restore permissions for cleanup
      File.chmod!(@test_config_file, 0o644)
    end
  end

  describe "ConfigParser configuration merging" do
    test "merges partial configuration with defaults" do
      # Create a partial config file (only proxy settings)
      partial_config = """
      proxy:
        port: 9999
        upstream: "9.9.9.9"
      """

      File.write!(@test_config_file, partial_config)
      Application.put_env(:tenbin_cache, :config_file, @test_config_file)

      {:ok, _pid} = TenbinCache.ConfigParser.start_link([])

      proxy_config = TenbinCache.ConfigParser.get_proxy_config()
      assert proxy_config["port"] == 9999  # Custom value
      assert proxy_config["upstream"] == "9.9.9.9"  # Custom value
      assert proxy_config["timeout"] == 5000  # Default value (not overridden)
      assert proxy_config["cache_enabled"] == true  # Default value

      server_config = TenbinCache.ConfigParser.get_server_config()
      assert server_config["packet_dump"] == false  # Default value (no server section in config)
      assert server_config["dump_dir"] == "log/dump"  # Default value
    end

    test "merges nested configuration properly" do
      # Test deep merging behavior
      nested_config = """
      proxy:
        port: 7777
        # upstream not specified, should use default
      server:
        packet_dump: true
        # dump_dir not specified, should use default
      """

      File.write!(@test_config_file, nested_config)
      Application.put_env(:tenbin_cache, :config_file, @test_config_file)

      {:ok, _pid} = TenbinCache.ConfigParser.start_link([])

      proxy_config = TenbinCache.ConfigParser.get_proxy_config()
      assert proxy_config["port"] == 7777  # Custom value
      assert proxy_config["upstream"] == "8.8.8.8"  # Default value

      server_config = TenbinCache.ConfigParser.get_server_config()
      assert server_config["packet_dump"] == true  # Custom value
      assert server_config["dump_dir"] == "log/dump"  # Default value
    end
  end

  describe "ConfigParser runtime operations" do
    test "reload configuration dynamically" do
      # Start with initial config
      initial_config = """
      proxy:
        port: 1111
      """

      File.write!(@test_config_file, initial_config)
      Application.put_env(:tenbin_cache, :config_file, @test_config_file)

      {:ok, _pid} = TenbinCache.ConfigParser.start_link([])

      initial_proxy = TenbinCache.ConfigParser.get_proxy_config()
      assert initial_proxy["port"] == 1111

      # Update config file
      updated_config = """
      proxy:
        port: 2222
        upstream: "2.2.2.2"
      """

      File.write!(@test_config_file, updated_config)

      # Reload configuration
      logs = capture_log(fn ->
        TenbinCache.ConfigParser.reload()
      end)

      assert logs =~ "Loading configuration from: #{@test_config_file}"
      assert logs =~ "Configuration loaded successfully"

      # Verify configuration was reloaded
      updated_proxy = TenbinCache.ConfigParser.get_proxy_config()
      assert updated_proxy["port"] == 2222
      assert updated_proxy["upstream"] == "2.2.2.2"
    end

    test "get_all returns complete configuration" do
      test_config = """
      proxy:
        port: 3333
      server:
        packet_dump: true
      """

      File.write!(@test_config_file, test_config)
      Application.put_env(:tenbin_cache, :config_file, @test_config_file)

      {:ok, _pid} = TenbinCache.ConfigParser.start_link([])

      all_config = TenbinCache.ConfigParser.get_all()

      assert is_map(all_config)
      assert Map.has_key?(all_config, "proxy")
      assert Map.has_key?(all_config, "server")
      assert all_config["proxy"]["port"] == 3333
      assert all_config["server"]["packet_dump"] == true
    end

    test "handles empty configuration sections gracefully" do
      empty_sections_config = """
      proxy: {}
      server: {}
      """

      File.write!(@test_config_file, empty_sections_config)
      Application.put_env(:tenbin_cache, :config_file, @test_config_file)

      {:ok, _pid} = TenbinCache.ConfigParser.start_link([])

      # Should merge with defaults properly
      proxy_config = TenbinCache.ConfigParser.get_proxy_config()
      assert proxy_config["port"] == 5353  # Default value

      server_config = TenbinCache.ConfigParser.get_server_config()
      assert server_config["packet_dump"] == false  # Default value
    end
  end

  describe "ConfigParser default path discovery" do
    test "uses default paths when no custom config specified" do
      # Don't set custom config file
      Application.delete_env(:tenbin_cache, :config_file)

      logs = capture_log(fn ->
        {:ok, _pid} = TenbinCache.ConfigParser.start_link([])
      end)

      # Should try to load from default paths and eventually find priv/test/tenbin_cache.yaml or use defaults
      # The exact message depends on which files exist in the test environment
      assert logs =~ "Loading configuration from:" or logs =~ "using defaults"
    end
  end
end