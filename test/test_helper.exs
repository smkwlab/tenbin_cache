# Compile test support modules
Code.compile_file(Path.join(__DIR__, "support/dns_test_helper.exs"))

# Set test-specific configuration
Application.put_env(:tenbin_cache, :config_file, "priv/test/tenbin_cache.yaml")

# Stop the application if it's running to prevent interference with unit tests
Application.stop(:tenbin_cache)

ExUnit.start()
