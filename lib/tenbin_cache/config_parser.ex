defmodule TenbinCache.ConfigParser do
  @moduledoc """
  Configuration file parser and management Agent for the TenbinCache DNS proxy server.

  This Agent loads, parses, and provides access to the main configuration
  file (`tenbin_cache.yaml`). It serves as the central configuration store for
  the DNS proxy server components.

  ## Configuration File

  The configuration is expected to be in YAML format with the following structure:

  ```yaml
  # DNS proxy server configuration
  proxy:
    port: 53                    # DNS server port
    upstream: "8.8.8.8"         # Upstream DNS server
    upstream_port: 53           # Upstream DNS port
    timeout: 5000               # Upstream timeout in milliseconds
    cache_enabled: true         # Enable response caching
    cache_ttl: 300              # Cache TTL in seconds

  # Server settings
  server:
    packet_dump: false          # Enable packet dumping for debugging
    dump_dir: "log/dump"        # Directory for packet dumps

  # Logging settings
  logging:
    dns_query_logging: true     # Enable DNS query/response logging
    log_level: "info"           # Log level (debug, info, warn, error)
    log_format: "json"          # Log format (json, text)
  ```

  ## Configuration Locations

  The parser searches for configuration files in the following order:
  1. `priv/` directory (development)
  2. Current working directory
  3. `/etc/tenbin_cache/` (system-wide configuration)

  ## Functionality

  - **YAML Parsing**: Loads and parses YAML configuration files
  - **Path Resolution**: Searches multiple locations for config files
  - **Validation**: Ensures required configuration sections exist
  - **Global Access**: Provides configuration data to all components

  ## Usage

  ```elixir
  # Get proxy configuration
  proxy_config = TenbinCache.ConfigParser.get_proxy_config()

  # Get server configuration
  server_config = TenbinCache.ConfigParser.get_server_config()

  # Get all configuration
  all_config = TenbinCache.ConfigParser.get_all()
  ```
  """

  use Agent
  require Logger

  # Default configuration file paths to search
  @config_search_paths [
    "priv/tenbin_cache.yaml",
    "tenbin_cache.yaml",
    "/etc/tenbin_cache/tenbin_cache.yaml"
  ]

  @default_config %{
    "proxy" => %{
      "port" => 5353,
      "upstream" => "8.8.8.8",
      "upstream_port" => 53,
      "timeout" => 5000,
      "cache_enabled" => true,
      "cache_ttl" => 300
    },
    "server" => %{
      "packet_dump" => false,
      "dump_dir" => "log/dump"
    },
    "logging" => %{
      "dns_query_logging" => true,
      "log_level" => "info",
      "log_format" => "json"
    }
  }

  # Public API

  def start_link(_) do
    Agent.start_link(&load_config/0, name: __MODULE__)
  end

  def get_all do
    Agent.get(__MODULE__, & &1)
  end

  def get_proxy_config do
    Agent.get(__MODULE__, &Map.get(&1, "proxy", %{}))
  end

  def get_server_config do
    Agent.get(__MODULE__, &Map.get(&1, "server", %{}))
  end

  def get_logging_config do
    Agent.get(__MODULE__, &Map.get(&1, "logging", %{}))
  end

  def dns_query_logging_enabled? do
    logging_config = get_logging_config()
    Map.get(logging_config, "dns_query_logging", true)
  end

  def reload do
    Agent.update(__MODULE__, fn _ -> load_config() end)
  end

  # Private functions

  defp load_config do
    case find_config_file() do
      {:ok, file_path} ->
        Logger.info("Loading configuration from: #{file_path}")
        parse_config_file(file_path)

      :not_found ->
        Logger.warning("Configuration file not found, using defaults")
        @default_config
    end
  end

  defp find_config_file do
    # Check if a specific config file is set in application environment (for tests)
    case Application.get_env(:tenbin_cache, :config_file) do
      nil -> find_config_in_default_paths()
      custom_path -> find_custom_config_file(custom_path)
    end
  end

  defp find_config_in_default_paths do
    Enum.find_value(@config_search_paths, :not_found, fn path ->
      if File.exists?(path) do
        {:ok, path}
      else
        nil
      end
    end)
  end

  defp find_custom_config_file(custom_path) do
    if File.exists?(custom_path) do
      {:ok, custom_path}
    else
      Logger.warning("Custom config file not found: #{custom_path}, falling back to defaults")
      :not_found
    end
  end

  defp parse_config_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, config} ->
            merged_config = deep_merge(@default_config, config)
            Logger.info("Configuration loaded successfully")
            merged_config

          {:error, reason} ->
            Logger.error("Failed to parse YAML config: #{inspect(reason)}")
            @default_config
        end

      {:error, reason} ->
        Logger.error("Failed to read config file #{file_path}: #{inspect(reason)}")
        @default_config
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_val, right_val ->
      deep_merge(left_val, right_val)
    end)
  end

  defp deep_merge(_left, right), do: right
end
