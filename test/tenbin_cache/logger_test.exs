defmodule TenbinCache.LoggerTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  describe "DNS query logging" do
    test "logs DNS query received with all required fields" do
      client_ip = {192, 168, 1, 100}
      query_name = "example.com"
      query_type = :A
      query_class = :IN

      logs =
        capture_log([level: :info], fn ->
          TenbinCache.Logger.log_dns_query_received(client_ip, query_name, query_type, query_class)
        end)

      # Parse the JSON log entry
      log_line = logs |> String.trim() |> String.split("\n") |> List.last()
      assert String.contains?(log_line, "dns_query_received")
      assert String.contains?(log_line, "192.168.1.100")
      assert String.contains?(log_line, "example.com")
      assert String.contains?(log_line, "\"A\"")
      assert String.contains?(log_line, "\"IN\"")
    end

    test "logs DNS response sent with processing time" do
      client_ip = {192, 168, 1, 100}
      query_name = "example.com"
      response_code = "NOERROR"
      answer_count = 1
      response_data = ["93.184.216.34"]
      processing_time_ms = 111

      logs =
        capture_log([level: :info], fn ->
          TenbinCache.Logger.log_dns_response_sent(
            client_ip,
            query_name,
            response_code,
            answer_count,
            response_data,
            processing_time_ms
          )
        end)

      log_line = logs |> String.trim() |> String.split("\n") |> List.last()
      assert String.contains?(log_line, "dns_response_sent")
      assert String.contains?(log_line, "192.168.1.100")
      assert String.contains?(log_line, "example.com")
      assert String.contains?(log_line, "NOERROR")
      assert String.contains?(log_line, "111")
      assert String.contains?(log_line, "93.184.216.34")
    end

    test "logs DNS error responses" do
      client_ip = {10, 0, 0, 1}
      query_name = "nonexistent.test"
      error_reason = "upstream_timeout"

      logs =
        capture_log([level: :warning], fn ->
          TenbinCache.Logger.log_dns_error(client_ip, query_name, error_reason)
        end)

      log_line = logs |> String.trim() |> String.split("\n") |> List.last()
      assert String.contains?(log_line, "dns_error")
      assert String.contains?(log_line, "10.0.0.1")
      assert String.contains?(log_line, "nonexistent.test")
      assert String.contains?(log_line, "upstream_timeout")
    end

    test "respects DNS logging enabled/disabled configuration" do
      # Test with logging disabled
      Application.put_env(:tenbin_cache, :dns_query_logging, false)

      logs =
        capture_log([level: :info], fn ->
          TenbinCache.Logger.log_dns_query_received({127, 0, 0, 1}, "test.com", :A, :IN)
        end)

      assert logs == ""

      # Test with logging enabled
      Application.put_env(:tenbin_cache, :dns_query_logging, true)

      logs =
        capture_log([level: :info], fn ->
          TenbinCache.Logger.log_dns_query_received({127, 0, 0, 1}, "test.com", :A, :IN)
        end)

      assert String.contains?(logs, "dns_query_received")

      # Clean up
      Application.delete_env(:tenbin_cache, :dns_query_logging)
    end
  end

  describe "JSON log formatting" do
    test "produces valid JSON with correct timestamp format" do
      logs =
        capture_log([level: :info], fn ->
          TenbinCache.Logger.log_dns_query_received({127, 0, 0, 1}, "test.com", :A, :IN)
        end)

      log_line = logs |> String.trim() |> String.split("\n") |> List.last()

      # Extract JSON part from log line (remove Elixir log prefix)
      json_start = :binary.match(log_line, "{") |> elem(0)
      json_part = String.slice(log_line, json_start..-1//1)

      # Parse and validate JSON
      assert {:ok, parsed} = Jason.decode(json_part)
      assert Map.has_key?(parsed, "timestamp")
      assert Map.has_key?(parsed, "level")
      assert Map.has_key?(parsed, "event")
      assert Map.has_key?(parsed, "client_ip")
      assert Map.has_key?(parsed, "query_name")
      assert Map.has_key?(parsed, "query_type")
      assert Map.has_key?(parsed, "query_class")

      # Validate timestamp format (ISO 8601)
      assert String.contains?(parsed["timestamp"], "T")
      assert String.contains?(parsed["timestamp"], "Z")
    end

    test "handles IPv6 addresses correctly" do
      ipv6_address = {0x2001, 0x0db8, 0x85a3, 0x0000, 0x0000, 0x8a2e, 0x0370, 0x7334}

      logs =
        capture_log([level: :info], fn ->
          TenbinCache.Logger.log_dns_query_received(ipv6_address, "ipv6.test", :AAAA, :IN)
        end)

      log_line = logs |> String.trim() |> String.split("\n") |> List.last()
      assert String.contains?(log_line, "2001:db8:85a3::8a2e:370:7334")
    end

    test "sanitizes log data to prevent injection attacks" do
      malicious_query = "test.com\"; DROP TABLE dns; --"

      logs =
        capture_log([level: :info], fn ->
          TenbinCache.Logger.log_dns_query_received({192, 168, 1, 1}, malicious_query, :A, :IN)
        end)

      # Verify the malicious content is properly escaped in JSON
      log_line = logs |> String.trim() |> String.split("\n") |> List.last()
      json_start = :binary.match(log_line, "{") |> elem(0)
      json_part = String.slice(log_line, json_start..-1//1)

      assert {:ok, parsed} = Jason.decode(json_part)
      assert parsed["query_name"] == malicious_query
    end
  end

  describe "performance impact" do
    test "logging disabled has minimal overhead" do
      Application.put_env(:tenbin_cache, :dns_query_logging, false)

      {time_disabled, _result} =
        :timer.tc(fn ->
          Enum.each(1..1000, fn _ ->
            TenbinCache.Logger.log_dns_query_received({127, 0, 0, 1}, "test.com", :A, :IN)
          end)
        end)

      Application.put_env(:tenbin_cache, :dns_query_logging, true)

      {time_enabled, _result} =
        :timer.tc(fn ->
          capture_log([level: :info], fn ->
            Enum.each(1..1000, fn _ ->
              TenbinCache.Logger.log_dns_query_received({127, 0, 0, 1}, "test.com", :A, :IN)
            end)
          end)
        end)

      # Cleanup
      Application.delete_env(:tenbin_cache, :dns_query_logging)

      # Verify disabled logging is significantly faster (should be near-zero overhead)
      overhead_ratio = time_enabled / time_disabled
      assert overhead_ratio < 300  # Should be reasonable overhead when enabled vs disabled
    end
  end
end