defmodule Helix.MixProject do
  use Mix.Project

  def project do
    [
      app: :helix,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      description: "Leaderless distributed transaction kernel in pure Elixir",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Helix.Application, []}
    ]
  end

  defp deps do
    []
  end

  defp package do
    [
      name: "helix",
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/Aneesh495/helix"}
    ]
  end

  defp aliases do
    [
      bench: ["run -e 'Helix.Benchmark.run()'"],
      chaos: ["run -e 'Helix.Chaos.ScenarioRunner.run_all()'"],
      tui: ["run --no-halt -e 'Helix.TUI.Dashboard.start()'"],
      verify: ["test", "run -e 'Helix.Chaos.ScenarioRunner.run_all()'"]
    ]
  end
end
