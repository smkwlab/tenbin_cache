defmodule TenbinCache.MixProject do
  use Mix.Project

  def project do
    [
      app: :tenbin_cache,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      dialyzer: dialyzer(),
      test_coverage: test_coverage()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {TenbinCache.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # DNS packet parsing library
      {:tenbin_dns, git: "https://github.com/smkwlab/tenbin_dns.git", tag: "0.7.1"},

      # YAML configuration parsing
      {:yaml_elixir, "~> 2.11"},

      # Development dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Pure DNS caching proxy server with transparent packet forwarding"
  end

  defp package do
    [
      maintainers: ["smkwlab"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/smkwlab/tenbin_cache"}
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling, :underspecs]
    ]
  end

  defp test_coverage do
    [
      summary: [threshold: 80]
    ]
  end
end
