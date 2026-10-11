defmodule KinyarwandaModeration.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/niyonkuruelisa/kinyarwanda_moderation"

  def project do
    [
      app: :kinyarwanda_moderation,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description: description(),
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      aliases: aliases(),
      name: "KinyarwandaModeration"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {KinyarwandaModeration, []}
    ]
  end

  # `mix test` refuses to run from inside an alias unless the environment is
  # pinned, since the alias itself runs in whichever env mix started in.
  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    """
    Open-source Kinyarwanda content moderation, profanity filtering and hate
    speech detection for Elixir and Phoenix. Normalizes the l/r spelling swap,
    diacritics, letter padding and noun-class prefixes that generic filters miss.
    """
  end

  defp package do
    [
      name: "kinyarwanda_moderation",
      files: ~w(lib data mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["MIT"],
      maintainers: ["Niyonkuru Elisa"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Issues" => "#{@source_url}/issues"
      },
      keywords: [
        "kinyarwanda",
        "moderation",
        "profanity",
        "profanity-filter",
        "hate-speech",
        "hate-speech-detection",
        "content-moderation",
        "bad-words",
        "text-sanitization",
        "rwanda",
        "african-languages",
        "nlp",
        "phoenix"
      ]
    ]
  end

  defp docs do
    [
      main: "KinyarwandaModeration",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test"
      ]
    ]
  end
end
