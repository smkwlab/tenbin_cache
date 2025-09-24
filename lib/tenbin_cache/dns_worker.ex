defmodule TenbinCache.DNSWorker do
  @moduledoc """
  DNS worker module for transparent packet forwarding in the TenbinCache DNS proxy server.

  This module handles the core DNS proxy functionality by forwarding DNS packets
  directly to upstream servers while preserving the original packet structure,
  including ADDITIONAL sections. This solves the Issue #123 problem by avoiding
  any DNS packet parsing or modification.

  ## Functionality

  - **Transparent Forwarding**: Forward DNS packets without modification
  - **ID Preservation**: Maintain original DNS packet IDs for proper client-server correlation
  - **Response Passthrough**: Return upstream responses directly to clients
  - **Optional Caching**: Cache responses to reduce upstream queries (configurable)
  - **Packet Logging**: Optional packet capture for debugging

  ## Proxy Processing Flow

  1. **Receive Packet**: Get raw DNS packet from client
  2. **Optional Logging**: Save incoming packet if debugging enabled
  3. **Upstream Forward**: Send packet to configured upstream DNS server
  4. **Response Receive**: Get response from upstream server
  5. **Optional Caching**: Cache response for future queries (if enabled)
  6. **Optional Logging**: Save outgoing packet if debugging enabled
  7. **Client Response**: Forward upstream response directly to client

  ## Key Differences from tenbin_ex

  - **No DNS Parsing**: Packets are treated as binary data
  - **No Zone Database**: No local DNS records or policies
  - **No Response Generation**: All responses come from upstream
  - **Simplified Architecture**: Pure proxy functionality only

  ## Error Handling

  - **Upstream Timeout**: Generate SERVFAIL response
  - **Network Errors**: Generate SERVFAIL response
  - **Invalid Responses**: Generate SERVFAIL response
  - **Configuration Errors**: Log error and generate SERVFAIL

  ## Performance

  - **Minimal Processing**: Binary packet forwarding only
  - **Concurrent Execution**: Multiple workers handle queries in parallel
  - **Memory Efficient**: No complex data structures or parsing
  - **Fast Response**: Direct packet forwarding without modification
  """

  require Logger

  @socket_buffer_size 65_535
  @servfail_rcode 2

  def worker({host, port, packet}, socket, packet_dump_config) do
    start_time = System.monotonic_time(:millisecond)

    # Extract DNS query information for logging
    {query_name, query_type, query_class} = extract_query_info(packet)

    # Log DNS query received
    TenbinCache.Logger.log_dns_query_received(host, query_name, query_type, query_class)

    # Save incoming packet for debugging
    packet = save_packet(packet, "in", packet_dump_config)

    case forward_to_upstream(packet) do
      {:ok, response_packet} ->
        processing_time = System.monotonic_time(:millisecond) - start_time
        {response_data, answer_count, response_code} = extract_response_info(response_packet)

        # Log successful DNS response
        TenbinCache.Logger.log_dns_response_sent(
          host,
          query_name,
          response_code,
          answer_count,
          response_data,
          processing_time
        )

        # Save outgoing packet and send response
        response_packet
        |> save_packet("out", packet_dump_config)
        |> send_reply(socket, host, port)

      {:error, reason} ->
        Logger.warning("DNS proxy forward failed: #{reason}")

        # Log DNS error
        TenbinCache.Logger.log_dns_error(host, query_name, format_error_reason(reason))

        # Generate SERVFAIL response and send
        generate_servfail_response(packet)
        |> save_packet("out", packet_dump_config)
        |> send_reply(socket, host, port)
    end
  rescue
    e ->
      Logger.error("Error in DNS proxy worker: #{inspect(e)}")
      :ok
  end

  # Forward DNS packet to upstream server with enhanced error handling
  defp forward_to_upstream(packet) do
    proxy_config = TenbinCache.ConfigParser.get_proxy_config()
    upstream = Map.get(proxy_config, "upstream", "8.8.8.8")
    upstream_port = Map.get(proxy_config, "upstream_port", 53)
    timeout = Map.get(proxy_config, "timeout", 5000)
    max_retries = Map.get(proxy_config, "max_retries", 2)

    upstream_addr = parse_upstream_address(upstream)

    forward_with_retries(packet, upstream, upstream_addr, upstream_port, timeout, max_retries)
  end

  # Forward with retry mechanism
  defp forward_with_retries(packet, upstream, upstream_addr, upstream_port, timeout, retries_left) do
    case attempt_forward(packet, upstream_addr, upstream_port, timeout) do
      {:ok, response_data} ->
        {:ok, response_data}

      {:error, reason} when retries_left > 0 ->
        log_retry_attempt(upstream, reason, retries_left)
        # Short delay before retry to avoid overwhelming the upstream server
        Process.sleep(100)

        forward_with_retries(
          packet,
          upstream,
          upstream_addr,
          upstream_port,
          timeout,
          retries_left - 1
        )

      {:error, reason} ->
        log_upstream_failure(upstream, reason)
        {:error, reason}
    end
  end

  # Single forward attempt
  defp attempt_forward(packet, upstream_addr, upstream_port, timeout) do
    with {:ok, socket} <- open_upstream_socket(),
         :ok <- send_to_upstream(socket, upstream_addr, upstream_port, packet),
         {:ok, response_data} <- receive_from_upstream(socket, timeout) do
      :gen_udp.close(socket)
      {:ok, response_data}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Open socket for upstream communication
  defp open_upstream_socket do
    case :gen_udp.open(0, [:binary, {:active, false}]) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, {:socket_open_failed, reason}}
    end
  end

  # Send packet to upstream server
  defp send_to_upstream(socket, upstream_addr, upstream_port, packet) do
    case :gen_udp.send(socket, upstream_addr, upstream_port, packet) do
      :ok -> :ok
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  end

  # Receive response from upstream server
  defp receive_from_upstream(socket, timeout) do
    case :gen_udp.recv(socket, @socket_buffer_size, timeout) do
      {:ok, {_addr, _port, response_data}} -> {:ok, response_data}
      {:error, :timeout} -> {:error, :upstream_timeout}
      {:error, reason} -> {:error, {:recv_failed, reason}}
    end
  end

  # Log retry attempts
  defp log_retry_attempt(upstream, reason, retries_left) do
    Logger.warning(
      "DNS forward to #{upstream} failed: #{format_error(reason)}, retrying (#{retries_left} attempts left)"
    )
  end

  # Log final upstream failure
  defp log_upstream_failure(upstream, reason) do
    case reason do
      :upstream_timeout ->
        Logger.error("Upstream DNS server #{upstream} timeout after all retries")

      {:socket_open_failed, socket_reason} ->
        Logger.error(
          "Failed to open socket for upstream DNS server #{upstream}: #{socket_reason}"
        )

      {:send_failed, send_reason} ->
        Logger.error("Failed to send query to upstream DNS server #{upstream}: #{send_reason}")

      {:recv_failed, recv_reason} ->
        Logger.error(
          "Failed to receive response from upstream DNS server #{upstream}: #{recv_reason}"
        )
    end
  end

  # Format error for logging
  defp format_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_error({:socket_open_failed, reason}), do: "socket open failed: #{reason}"
  defp format_error({:send_failed, reason}), do: "send failed: #{reason}"
  defp format_error({:recv_failed, reason}), do: "receive failed: #{reason}"

  # Format error reason for DNS error logging
  defp format_error_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_error_reason({:socket_open_failed, _reason}), do: "upstream_connection_failed"
  defp format_error_reason({:send_failed, _reason}), do: "upstream_send_failed"
  defp format_error_reason({:recv_failed, _reason}), do: "upstream_receive_failed"
  defp format_error_reason(:upstream_timeout), do: "upstream_timeout"

  # Extract query information from DNS packet
  defp extract_query_info(packet) do
    try do
      parsed = DNSpacket.parse(packet)
      question = List.first(parsed.question) || %{}

      query_name = Map.get(question, :qname, "unknown")
      query_type = Map.get(question, :qtype, :UNKNOWN)
      query_class = Map.get(question, :qclass, :IN)

      {query_name, query_type, query_class}
    rescue
      FunctionClauseError ->
        {"parse_error", :UNKNOWN, :IN}

      ArgumentError ->
        {"parse_error", :UNKNOWN, :IN}

      e in [MatchError, KeyError] ->
        Logger.debug("DNS packet parse error: #{inspect(e)}")
        {"parse_error", :UNKNOWN, :IN}
    end
  end

  # Extract response information from DNS packet
  defp extract_response_info(packet) do
    try do
      parsed = DNSpacket.parse(packet)

      # Extract response code
      response_code =
        case parsed.rcode do
          0 -> "NOERROR"
          1 -> "FORMERR"
          2 -> "SERVFAIL"
          3 -> "NXDOMAIN"
          4 -> "NOTIMP"
          5 -> "REFUSED"
          _ -> "UNKNOWN"
        end

      # Count answers
      answer_count = length(parsed.answer || [])

      # Extract answer data (simplified)
      response_data =
        parsed.answer
        |> Enum.map(fn answer ->
          case answer do
            %{rdata: rdata} when is_tuple(rdata) ->
              # Use Logger's format_ip_address function for proper IPv4/IPv6 handling
              TenbinCache.Logger.format_ip_address(rdata)

            %{rdata: rdata} when is_binary(rdata) ->
              rdata

            _ ->
              "unknown"
          end
        end)

      {response_data, answer_count, response_code}
    rescue
      FunctionClauseError ->
        {[], 0, "PARSE_ERROR"}

      ArgumentError ->
        {[], 0, "PARSE_ERROR"}

      e in [MatchError, KeyError] ->
        Logger.debug("DNS response parse error: #{inspect(e)}")
        {[], 0, "PARSE_ERROR"}
    end
  end

  # Parse upstream forwarder address
  defp parse_upstream_address(addr) when is_binary(addr) do
    case :inet.parse_address(String.to_charlist(addr)) do
      {:ok, ip_tuple} -> ip_tuple
      # Fallback to localhost
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  # Generate SERVFAIL response for errors
  defp generate_servfail_response(original_packet) do
    # Parse the original packet to get the header information
    parsed_packet = DNSpacket.parse(original_packet)

    # Create SERVFAIL response
    servfail_packet = %{
      parsed_packet
      | qr: 1,
        rcode: @servfail_rcode,
        answer: [],
        authority: [],
        additional: []
    }

    DNSpacket.create(servfail_packet)
  rescue
    e in [FunctionClauseError, ArgumentError, MatchError, KeyError] ->
      # If parsing fails, create a minimal SERVFAIL response
      # This is a fallback for completely malformed packets
      Logger.warning("Failed to parse packet for SERVFAIL response: #{inspect(e)}")
      create_minimal_servfail()
  end

  # Create minimal SERVFAIL response when packet parsing fails
  defp create_minimal_servfail do
    minimal_packet = %DNSpacket{
      id: :rand.uniform(65_535),
      qr: 1,
      opcode: 0,
      aa: 0,
      tc: 0,
      rd: 1,
      ra: 0,
      z: 0,
      ad: 0,
      cd: 0,
      rcode: @servfail_rcode,
      question: [],
      answer: [],
      authority: [],
      additional: [],
      edns_info: nil
    }

    DNSpacket.create(minimal_packet)
  end

  # Save packet to file for debugging (similar to tenbin_ex implementation)
  defp save_packet(packet, _dir, false), do: packet

  defp save_packet(packet, dir, dump_dir) do
    {{y, m, d}, {hh, mm, ss}} = :calendar.local_time()
    {ms, _prec} = Time.utc_now().microsecond

    file_name =
      "dns_packet-#{dir}-#{y}#{String.pad_leading("#{m}", 2, "0")}#{String.pad_leading("#{d}", 2, "0")}-#{String.pad_leading("#{hh}", 2, "0")}#{String.pad_leading("#{mm}", 2, "0")}#{String.pad_leading("#{ss}", 2, "0")}.#{ms}.bin"

    file_path = Path.join(dump_dir, file_name)

    case File.open(file_path, [:write, :binary]) do
      {:ok, file} ->
        IO.binwrite(file, packet)
        File.close(file)
        packet

      {:error, reason} ->
        Logger.error("Failed to save packet to #{file_path}: #{inspect(reason)}")
        packet
    end
  end

  # Send DNS response to client
  defp send_reply(packet, socket, host, port) do
    case :gen_udp.send(socket, host, port, packet) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to send DNS reply: #{inspect(reason)}")
        :ok
    end
  end
end
