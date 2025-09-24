# Compile test support modules
Code.compile_file(Path.join(__DIR__, "support/dns_test_helper.exs"))

# Set test-specific configuration
Application.put_env(:tenbin_cache, :config_file, "priv/test/tenbin_cache.yaml")

# Stop the application if it's running to prevent interference with unit tests
Application.stop(:tenbin_cache)

ExUnit.start()

defmodule TestHelper do
  @doc """
  Simple test helper that doesn't start the full application.
  Use this for unit tests that don't require UDP servers.
  """
  def setup_test_env do
    # Ensure test configuration is available
    unless File.exists?("priv/test/tenbin_cache.yaml") do
      raise "Test configuration not found - check priv/test/tenbin_cache.yaml"
    end

    :ok
  end

  @doc """
  Start only essential components without UDP servers for testing.
  This prevents the UDP socket warnings that occur during normal application startup.
  """
  def start_tenbin_cache_for_test do
    Application.stop(:tenbin_cache)
    setup_test_env()

    # Start only required dependencies
    Application.ensure_all_started(:logger)
    Application.ensure_all_started(:yaml_elixir)

    # Start only ConfigParser without the full application
    try do
      case TenbinCache.ConfigParser.start_link([]) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      # Start TaskSupervisor if needed
      case Task.Supervisor.start_link(name: TenbinCache.TaskSupervisor) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      :ok
    catch
      :exit, reason ->
        case reason do
          {:already_started, _} ->
            :ok
          _ ->
            IO.puts("Failed to start TenbinCache for test: #{inspect(reason)}")
            raise "Test setup failed"
        end
    end
  end

  @doc """
  Ensure ConfigParser is running for tests that require it.
  This is a common pattern used across multiple tests.
  """
  def ensure_config_parser do
    unless Process.whereis(TenbinCache.ConfigParser) do
      {:ok, _pid} = TenbinCache.ConfigParser.start_link([])
    end
    :ok
  end

  def stop_tenbin_cache do
    Application.stop(:tenbin_cache)
  end

  def with_tenbin_cache(test_fn) do
    start_tenbin_cache_for_test()

    try do
      test_fn.()
    after
      stop_tenbin_cache()
    end
  end
end
