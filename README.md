# TenbinCache

Pure DNS caching proxy server with transparent packet forwarding, built with Elixir/OTP.

TenbinCache is designed as a lightweight DNS proxy that solves the ADDITIONAL SECTION preservation issue (Issue #123) by forwarding DNS packets transparently without modification. Unlike complex DNS servers, TenbinCache focuses solely on proxy functionality with minimal packet inspection.

## Features

- **Transparent Packet Forwarding**: Preserves all DNS packet sections including ADDITIONAL
- **ID Preservation**: Maintains original DNS packet IDs for proper client correlation
- **Optional Caching**: Configurable response caching to reduce upstream queries
- **Concurrent Processing**: High-performance concurrent UDP server
- **Packet Debugging**: Optional packet dumping for troubleshooting
- **Simple Configuration**: YAML-based configuration similar to tenbin_ex

## Architecture

TenbinCache follows the same architectural patterns as tenbin_ex but simplified for pure proxy functionality:

```
TenbinCache.Application
├── TenbinCache.ConfigParser (Agent)
├── Task.Supervisor (for DNS workers)
└── TenbinCache.UDPServerSupervisor
    └── TenbinCache.UDPServer (GenServer)
        └── TenbinCache.DNSWorker (Tasks)
```

## Quick Start

1. **Install dependencies**:
   ```bash
   mix deps.get
   ```

2. **Configure the proxy** (edit `priv/tenbin_cache.yaml`):
   ```yaml
   proxy:
     port: 5353
     upstream: "8.8.8.8"
     upstream_port: 53
     timeout: 5000
     cache_enabled: true
     cache_ttl: 300
   ```

3. **Start the server**:
   ```bash
   mix run --no-halt
   ```

4. **Test DNS queries**:
   ```bash
   dig @localhost -p 5353 google.com A
   ```

## Configuration

The server is configured via `priv/tenbin_cache.yaml`:

### Proxy Settings
- `port`: DNS server port (default: 5353)
- `upstream`: Upstream DNS server IP (default: "8.8.8.8")
- `upstream_port`: Upstream DNS port (default: 53)
- `timeout`: Upstream query timeout in milliseconds (default: 5000)
- `cache_enabled`: Enable response caching (default: true)
- `cache_ttl`: Cache TTL in seconds (default: 300)

### Server Settings
- `packet_dump`: Enable packet debugging (default: false)
- `dump_dir`: Directory for packet dumps (default: "log/dump")

## Development

### Running Tests
```bash
mix test
```

### Code Quality
```bash
mix credo
mix dialyzer
```

### Running in Development
```bash
# Standard mode
mix run --no-halt

# With packet debugging
# (edit config to set packet_dump: true)
mix run --no-halt
```

## Comparison with tenbin_ex

| Feature | tenbin_ex | tenbin_cache |
|---------|-----------|--------------|
| DNS Parsing | Full packet parsing | Minimal (binary forwarding) |
| Local Records | Zone files + policies | None (pure proxy) |
| Response Generation | Dynamic policies | Upstream only |
| ADDITIONAL Section | Modified during processing | Preserved from upstream |
| Configuration | Complex (zones, policies) | Simple (proxy settings) |
| Use Case | Authoritative DNS server | DNS proxy/forwarder |

## Use Cases

- **Corporate DNS Proxy**: Forward internal DNS queries to external resolvers
- **ADDITIONAL Section Preservation**: Maintain DNS response integrity
- **Simple DNS Caching**: Reduce upstream queries with configurable caching
- **DNS Debugging**: Packet-level debugging with dump functionality
- **Load Balancing**: Distribute queries across multiple upstream servers

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `tenbin_cache` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tenbin_cache, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/tenbin_cache>.

## License

MIT License

## Related Projects

- [tenbin_ex](https://github.com/smkwlab/tenbin_ex) - Full-featured DNS server with policy system
- [tenbin_dns](https://github.com/smkwlab/tenbin_dns) - DNS packet parsing library
- [tdig](https://github.com/smkwlab/tdig) - DNS lookup CLI tool
