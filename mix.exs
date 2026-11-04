defmodule TravelingPoet.MixProject do
  use Mix.Project

  def project do
    [
      app: :traveling_poet,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      # No file:line comments in priv/gettext: they would churn with every
      # edit and trip precommit's gettext.extract --check-up-to-date
      gettext: [write_reference_comments: false]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {TravelingPoet.Application, []},
      # :public_key for TravelingPoet.JWS (Apple's .p8 keys and JWK sets)
      extra_applications: [:logger, :runtime_tools, :public_key]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_google, "~> 0.12"},
      {:websockex, "~> 0.4"},
      {:req, "~> 0.5"},
      {:alice_in_context,
       git: "https://github.com/AliceAlifib/alice-in-context.git",
       sparse: "packages/aic-client-ex",
       ref: "601c435a4609bd7b8aeef5f495e858c03f6f0e3e"},
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},
      {:hackney, "~> 1.20"},
      {:mdex, "~> 0.12"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": [
        "compile",
        "tailwind traveling_poet",
        "tailwind book",
        "esbuild traveling_poet"
      ],
      "assets.deploy": [
        "tailwind traveling_poet --minify",
        "tailwind book --minify",
        "esbuild traveling_poet --minify",
        "phx.digest"
      ],
      # gettext.extract --check-up-to-date fails when a string changed in the
      # code but not in priv/gettext (TranslationsTest then checks the Hebrew).
      # It force-recompiles every module, so it runs in its own VM and on the
      # dev build: on the test build it left the next precommit's `compile`
      # redefining loaded modules, which --warnings-as-errors failed.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "cmd env MIX_ENV=dev mix gettext.extract --check-up-to-date",
        "test"
      ]
    ]
  end
end
