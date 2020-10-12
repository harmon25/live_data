defmodule LiveData.MixProject do
  use Mix.Project

  def project do
    [
      app: :live_data,
      version: "0.1.0",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.0"},
      {:json_diff, "~> 0.1.2"},
      {:morphix, "~> 0.8.0"},
      {:dialyxir, "~> 1.0.0-rc.7", only: [:dev], runtime: false},
      {:json_xema, "~> 0.3"},
      {:parent, "~> 0.11.0-rc.0"},
      {:phoenix, "~> 1.5"}
    ]
  end
end
