defmodule TenbinCache.Logger do
  @moduledoc """
  DNS query and response logging module for TenbinCache.

  Provides structured JSON logging for DNS queries, responses, and errors.
  Logging can be enabled/disabled via application configuration.

  ## Configuration

  Set in config or via Application.put_env/3:

      config :tenbin_cache, :dns_query_logging, true

  ## Log Format

  All logs are output as JSON with ISO 8601 timestamps:

      {
        "timestamp": "2024-09-24T14:30:45.123Z",
        "level": "info",
        "event": "dns_query_received",
        "client_ip": "192.168.1.100",
        "query_name": "example.com",
        "query_type": "A",
        "query_class": "IN"
      }
  """

  require Logger

  @doc """
  Log a DNS query received from a client.

  ## Parameters

  - client_ip: Client IP address tuple (IPv4 or IPv6)
  - query_name: DNS query name (string)
  - query_type: DNS query type (atom)
  - query_class: DNS query class (atom)

  ## Examples

      iex> TenbinCache.Logger.log_dns_query_received({192, 168, 1, 100}, "example.com", :A, :IN)
      :ok
  """
  def log_dns_query_received(client_ip, query_name, query_type, query_class) do
    if dns_logging_enabled?() do
      log_data = %{
        timestamp: iso8601_timestamp(),
        level: "info",
        event: "dns_query_received",
        client_ip: format_ip_address(client_ip),
        query_name: query_name,
        query_type: Atom.to_string(query_type),
        query_class: Atom.to_string(query_class)
      }

      Logger.info(Jason.encode!(log_data))
    end

    :ok
  end

  @doc """
  Log a DNS response sent to a client.

  ## Parameters

  - client_ip: Client IP address tuple (IPv4 or IPv6)
  - query_name: DNS query name (string)
  - response_code: DNS response code (string)
  - answer_count: Number of answers in response (integer)
  - response_data: List of response data (list of strings)
  - processing_time_ms: Processing time in milliseconds (integer)

  ## Examples

      iex> TenbinCache.Logger.log_dns_response_sent({192, 168, 1, 100}, "example.com", "NOERROR", 1, ["93.184.216.34"], 15)
      :ok
  """
  def log_dns_response_sent(
        client_ip,
        query_name,
        response_code,
        answer_count,
        response_data,
        processing_time_ms
      ) do
    if dns_logging_enabled?() do
      log_data = %{
        timestamp: iso8601_timestamp(),
        level: "info",
        event: "dns_response_sent",
        client_ip: format_ip_address(client_ip),
        query_name: query_name,
        response_code: response_code,
        answer_count: answer_count,
        response_data: response_data,
        processing_time_ms: processing_time_ms
      }

      Logger.info(Jason.encode!(log_data))
    end

    :ok
  end

  @doc """
  Log a DNS error.

  ## Parameters

  - client_ip: Client IP address tuple (IPv4 or IPv6)
  - query_name: DNS query name (string)
  - error_reason: Error reason description (string)

  ## Examples

      iex> TenbinCache.Logger.log_dns_error({10, 0, 0, 1}, "nonexistent.test", "upstream_timeout")
      :ok
  """
  def log_dns_error(client_ip, query_name, error_reason) do
    if dns_logging_enabled?() do
      log_data = %{
        timestamp: iso8601_timestamp(),
        level: "warn",
        event: "dns_error",
        client_ip: format_ip_address(client_ip),
        query_name: query_name,
        error_reason: error_reason
      }

      Logger.warning(Jason.encode!(log_data))
    end

    :ok
  end

  @doc """
  Format IP address tuple to string representation.

  Uses Erlang's :inet.ntoa/1 for proper IPv4/IPv6 formatting according to RFCs.

  ## Parameters

  - ip_tuple: IP address tuple (IPv4 4-tuple or IPv6 8-tuple)

  ## Examples

      iex> TenbinCache.Logger.format_ip_address({192, 168, 1, 1})
      "192.168.1.1"

      iex> TenbinCache.Logger.format_ip_address({0x2001, 0x0db8, 0, 0, 0, 0, 0, 1})
      "2001:db8::1"
  """
  def format_ip_address(ip_tuple) when tuple_size(ip_tuple) == 4 or tuple_size(ip_tuple) == 8 do
    # Use Erlang's inet:ntoa/1 for proper IP address formatting
    # This handles both IPv4 and IPv6 addresses correctly according to RFCs
    case :inet.ntoa(ip_tuple) do
      {:error, _} -> "invalid_ip"
      formatted_ip -> List.to_string(formatted_ip)
    end
  end

  # Private functions

  defp dns_logging_enabled? do
    # First check Application environment (for tests)
    case Application.get_env(:tenbin_cache, :dns_query_logging) do
      nil ->
        # Fall back to ConfigParser if available
        try do
          TenbinCache.ConfigParser.dns_query_logging_enabled?()
        catch
          # Default to enabled if ConfigParser not available
          :exit, _ -> true
        end

      value ->
        value
    end
  end

  defp iso8601_timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
  end
end
