defmodule TenbinCache.DNSLoggingIntegrationTest do
  @moduledoc """
  Integration tests for DNS logging functionality.

  These tests verify that the DNS logging system works end-to-end
  with the ConfigParser and Logger modules.
  """

  use ExUnit.Case
  import ExUnit.CaptureLog

  setup do
    # Ensure ConfigParser is started for these tests
    unless Process.whereis(TenbinCache.ConfigParser) do
      {:ok, _pid} = TenbinCache.ConfigParser.start_link([])
    end

    :ok
  end

  describe "DNS logging integration" do
    test "ConfigParser provides correct logging configuration" do
      logging_config = TenbinCache.ConfigParser.get_logging_config()

      # Verify default configuration values are loaded
      assert is_map(logging_config)
      assert Map.has_key?(logging_config, "dns_query_logging")
      assert Map.has_key?(logging_config, "log_level")
      assert Map.has_key?(logging_config, "log_format")

      # Verify default values
      assert logging_config["dns_query_logging"] == true
      assert logging_config["log_level"] == "info"
      assert logging_config["log_format"] == "json"
    end

    test "Logger respects ConfigParser settings when available" do
      # Ensure ConfigParser is returning enabled logging
      assert TenbinCache.ConfigParser.dns_query_logging_enabled?() == true

      # Test logging with ConfigParser available
      logs =
        capture_log([level: :info], fn ->
          TenbinCache.Logger.log_dns_query_received({127, 0, 0, 1}, "test.com", :A, :IN)
        end)

      assert String.contains?(logs, "dns_query_received")
      assert String.contains?(logs, "127.0.0.1")
      assert String.contains?(logs, "test.com")
    end

    test "Logger falls back gracefully when ConfigParser unavailable" do
      # Stop ConfigParser temporarily
      if pid = Process.whereis(TenbinCache.ConfigParser) do
        Process.exit(pid, :kill)
        # Wait for process to be gone
        Process.sleep(10)
      end

      # Logging should still work with fallback to default (enabled)
      logs =
        capture_log([level: :info], fn ->
          TenbinCache.Logger.log_dns_query_received({127, 0, 0, 1}, "fallback.test", :A, :IN)
        end)

      assert String.contains?(logs, "dns_query_received")
      assert String.contains?(logs, "fallback.test")

      # Restart ConfigParser for cleanup
      {:ok, _pid} = TenbinCache.ConfigParser.start_link([])
    end

    test "DNS logging can be disabled via configuration" do
      # Create a temporary config file with logging disabled
      temp_config_content = """
      proxy:
        port: 5353
        upstream: "8.8.8.8"
        upstream_port: 53
        timeout: 5000
        cache_enabled: true
        cache_ttl: 300
      server:
        packet_dump: false
        dump_dir: "log/dump"
      logging:
        dns_query_logging: false
        log_level: "info"
        log_format: "json"
      """

      temp_config_path = "/tmp/tenbin_cache_test_disabled.yaml"
      File.write!(temp_config_path, temp_config_content)

      # Set custom config file in application environment
      old_config_file = Application.get_env(:tenbin_cache, :config_file)
      Application.put_env(:tenbin_cache, :config_file, temp_config_path)

      # Reload configuration
      TenbinCache.ConfigParser.reload()

      # Verify logging is now disabled
      assert TenbinCache.ConfigParser.dns_query_logging_enabled?() == false

      # Test that logging is disabled
      logs =
        capture_log([level: :info], fn ->
          TenbinCache.Logger.log_dns_query_received({127, 0, 0, 1}, "disabled.test", :A, :IN)
        end)

      assert logs == ""

      # Cleanup
      if old_config_file do
        Application.put_env(:tenbin_cache, :config_file, old_config_file)
      else
        Application.delete_env(:tenbin_cache, :config_file)
      end

      TenbinCache.ConfigParser.reload()
      File.rm(temp_config_path)
    end

    test "JSON log format validation with real ConfigParser" do
      logs =
        capture_log([level: :info], fn ->
          TenbinCache.Logger.log_dns_query_received({192, 168, 1, 1}, "json.test", :AAAA, :IN)
        end)

      log_line = logs |> String.trim() |> String.split("\n") |> List.last()

      # Extract JSON from log line
      json_start = :binary.match(log_line, "{") |> elem(0)
      json_part = String.slice(log_line, json_start..-1//1)

      # Validate JSON structure
      assert {:ok, parsed} = Jason.decode(json_part)
      assert parsed["event"] == "dns_query_received"
      assert parsed["client_ip"] == "192.168.1.1"
      assert parsed["query_name"] == "json.test"
      assert parsed["query_type"] == "AAAA"
      assert parsed["query_class"] == "IN"
      assert parsed["level"] == "info"
      assert String.contains?(parsed["timestamp"], "T")
      assert String.contains?(parsed["timestamp"], "Z")
    end
  end

  describe "Error handling integration" do
    test "Logger handles DNS errors correctly with ConfigParser" do
      logs =
        capture_log([level: :warning], fn ->
          TenbinCache.Logger.log_dns_error({10, 0, 0, 1}, "error.test", "upstream_timeout")
        end)

      log_line = logs |> String.trim() |> String.split("\n") |> List.last()
      assert String.contains?(log_line, "dns_error")
      assert String.contains?(log_line, "10.0.0.1")
      assert String.contains?(log_line, "error.test")
      assert String.contains?(log_line, "upstream_timeout")
    end

    test "Logger handles response logging with ConfigParser" do
      logs =
        capture_log([level: :info], fn ->
          TenbinCache.Logger.log_dns_response_sent(
            {172, 16, 0, 1},
            "response.test",
            "NOERROR",
            2,
            ["1.2.3.4", "5.6.7.8"],
            45
          )
        end)

      log_line = logs |> String.trim() |> String.split("\n") |> List.last()
      assert String.contains?(log_line, "dns_response_sent")
      assert String.contains?(log_line, "172.16.0.1")
      assert String.contains?(log_line, "response.test")
      assert String.contains?(log_line, "NOERROR")
      assert String.contains?(log_line, "45")
    end
  end
end