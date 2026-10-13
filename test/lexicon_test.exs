defmodule KinyarwandaModeration.LexiconTest do
  use ExUnit.Case, async: true

  alias KinyarwandaModeration.Lexicon
  alias KinyarwandaModeration.Tmp

  doctest KinyarwandaModeration.Lexicon

  @flat_notice "A flat term list carries no version, locale, severity or action metadata, " <>
                 "so it was loaded as a single \"flat_terms\" category with " <>
                 "severity :medium and action :flag."

  defp structured(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => "1.2.3",
        "locale" => "rw",
        "categories" => [
          %{
            "id" => "x",
            "label" => "X",
            "severity" => "low",
            "action" => "flag",
            "terms" => ["aaa"]
          }
        ]
      },
      overrides
    )
  end

  describe "default_path/1" do
    test "points at the bundled lexicon" do
      assert Path.basename(Lexicon.default_path()) == "rw_lexicon.json"
      assert Path.basename(Lexicon.default_path(from: :release)) == "rw_lexicon.json"
      assert Path.basename(Lexicon.default_path(%{from: :release})) == "rw_lexicon.json"
    end

    test "resolves inside the top-level data/ directory, not priv/" do
      assert Path.basename(Path.dirname(Lexicon.default_path())) == "data"
      assert File.regular?(Lexicon.default_path())
    end

    test "exposes the searched candidates in a stable, de-duplicated order" do
      candidates = Lexicon.default_path_candidates()

      assert candidates == Enum.uniq(candidates)
      assert candidates != []
      assert Enum.any?(candidates, &String.ends_with?(&1, "/data/rw_lexicon.json"))

      assert Lexicon.default_path_candidates(from: :release) != candidates
    end

    test "falls back to a source-tree path when the built copy is absent" do
      source = Enum.find(Lexicon.default_path_candidates(), &File.regular?/1)

      refute is_nil(source)
      refute String.contains?(source, "_build")
    end
  end

  describe "load/2" do
    test "loads the bundled lexicon by default" do
      lexicon = Lexicon.load()
      assert lexicon.version == "0.1.0"
      assert lexicon.locale == "rw"
      assert Lexicon.load(:default).version == "0.1.0"
      assert Lexicon.size(lexicon) == 10
    end

    test "accepts a directory and looks the bundled file up inside it" do
      assert Lexicon.load(Path.dirname(Lexicon.default_path())).path == Lexicon.default_path()
    end

    test "treats a flat array of terms as one category" do
      path = Path.join([Path.dirname(Lexicon.default_path()), "rw_hate_speech.json"])
      lexicon = Lexicon.load(path)

      assert lexicon.version == "0.0.0"
      assert lexicon.locale == "rw"
      assert lexicon.notice == @flat_notice
      assert Lexicon.size(lexicon) == 38

      assert [category] = lexicon.categories
      assert category.id == "flat_terms"
      assert category.label == "Flat term list"
      assert category.description == nil
      assert category.action == :flag
      assert category.severity == :medium
      assert category.term_count == 37
    end

    test "raises when the file does not exist" do
      missing = Tmp.missing("definitely_absent_lexicon.json")
      refute File.exists?(missing)

      assert_raise ArgumentError, "no lexicon found at #{missing}", fn ->
        Lexicon.load(missing)
      end
    end

    test "raises on malformed JSON" do
      path = Tmp.write!("kinyarwanda_moderation_broken.json", "{")
      on_exit(fn -> File.rm(path) end)

      message = assert_raise ArgumentError, fn -> Lexicon.load(path) end
      assert message.message =~ "is not valid JSON"
      assert message.message =~ path
    end
  end

  describe "build/3" do
    test "accepts a decoded map" do
      lexicon = Lexicon.build(structured())
      assert lexicon.version == "1.2.3"
      assert lexicon.path == nil
      assert Lexicon.size(lexicon) == 1
    end

    test "defaults a category's action and severity" do
      raw = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "categories" => [%{"id" => "x", "terms" => ["aaa"]}]
      }

      assert [category] = Lexicon.build(raw).categories
      assert category.action == :review
      assert category.severity == :medium
    end

    test "folds phrases into the same entry list as terms" do
      raw = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "categories" => [%{"id" => "x", "terms" => ["aaa"], "phrases" => ["aaa bbb"]}]
      }

      lexicon = Lexicon.build(raw)
      assert Lexicon.size(lexicon) == 3
      assert [category] = lexicon.categories
      assert category.term_count == 2

      assert Enum.map(lexicon.entries, & &1.term) == ["aaa", "aaa bbb", "aaabbb"]
    end

    test "gives every phrase a space-stripped alias carrying the normalized token" do
      raw = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "categories" => [%{"id" => "x", "phrases" => ["AbaDeputa Yego"]}]
      }

      lexicon = Lexicon.build(raw)
      assert [phrase, glued] = lexicon.entries

      assert phrase.tokens == ["abadeputa", "yego"]
      assert phrase.term_count == 2

      # `term` keeps the writer's spelling, `tokens` holds what the automaton
      # stores, and the alias is a single token so its span stays one wide.
      assert glued.term == "AbaDeputaYego"
      assert glued.tokens == ["abadeputayego"]
      assert glued.term_count == 1
      assert glued.category_id == phrase.category_id
      assert glued.action == phrase.action
    end

    test "skips the alias when gluing is not idempotent" do
      # A hyphen or comma inside the phrase makes the glued form tokenize into
      # more than one token, so an alias would not be the single token it claims.
      raw = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "categories" => [%{"id" => "x", "phrases" => ["aba-dep uta", "aaa bbb"]}]
      }

      lexicon = Lexicon.build(raw)

      assert Enum.map(lexicon.entries, & &1.term) == ["aba-dep uta", "aaa bbb", "aaabbb"]
    end

    test "skips the alias when the lexicon turns phrase gluing off" do
      raw = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "normalization" => %{"glued_phrases" => false},
        "categories" => [%{"id" => "x", "phrases" => ["aaa bbb"]}]
      }

      lexicon = Lexicon.build(raw)
      assert Enum.map(lexicon.entries, & &1.term) == ["aaa bbb"]
    end

    test "lets the caller override the normalization the lexicon declares" do
      raw = structured(%{"normalization" => %{"strip_prefixes" => false}})

      assert Lexicon.build(raw, nil, strip_prefixes: true).normalization.strip_prefixes == true
      assert Lexicon.build(raw, nil, []).normalization.strip_prefixes == false
    end

    test "raises when the top-level shape is neither an object nor an array" do
      assert_raise ArgumentError,
                   "lexicon must decode to a JSON object or an array of terms, got: \"nope\"",
                   fn -> Lexicon.build("nope") end
    end

    test "raises when version is missing" do
      assert_raise ArgumentError,
                   "lexicon is missing a non-empty \"version\" (got nil)",
                   fn -> Lexicon.build(Map.delete(structured(), "version")) end
    end

    test "raises when locale is missing" do
      assert_raise ArgumentError,
                   "lexicon is missing a non-empty \"locale\" (got nil)",
                   fn -> Lexicon.build(Map.delete(structured(), "locale")) end
    end

    test "raises when categories are absent or empty" do
      assert_raise ArgumentError,
                   "lexicon must define a non-empty \"categories\" array (got [])",
                   fn -> Lexicon.build(structured(%{"categories" => []})) end

      assert_raise ArgumentError,
                   "lexicon must define a non-empty \"categories\" array (got nil)",
                   fn -> Lexicon.build(Map.delete(structured(), "categories")) end
    end

    test "raises on an unknown severity, naming the allowed values" do
      raw =
        structured(%{"categories" => [%{"id" => "x", "severity" => "nope", "terms" => ["aaa"]}]})

      assert_raise ArgumentError,
                   "severity \"nope\" on category \"x\" in lexicon is not one of " <>
                     "[\"high\", \"low\", \"medium\"]",
                   fn -> Lexicon.build(raw) end
    end

    test "raises on an unknown action, naming the allowed values" do
      raw =
        structured(%{"categories" => [%{"id" => "x", "action" => "nope", "terms" => ["aaa"]}]})

      assert_raise ArgumentError,
                   "action \"nope\" on category \"x\" in lexicon is not one of " <>
                     "[\"allow\", \"flag\", \"reject\", \"review\"]",
                   fn -> Lexicon.build(raw) end
    end

    test "raises when a category is not an object" do
      assert_raise ArgumentError,
                   "category #0 in lexicon must be an object, got: \"nope\"",
                   fn -> Lexicon.build(structured(%{"categories" => ["nope"]})) end
    end

    test "raises when a category has no id" do
      assert_raise ArgumentError,
                   "category #0 in lexicon is missing a non-empty \"id\" (got nil)",
                   fn -> Lexicon.build(structured(%{"categories" => [%{"terms" => ["aaa"]}]})) end
    end

    test "raises when a category defines nothing to match" do
      assert_raise ArgumentError,
                   "category \"x\" in lexicon defines no terms or phrases",
                   fn -> Lexicon.build(structured(%{"categories" => [%{"id" => "x"}]})) end
    end

    test "raises when terms is not an array" do
      raw = structured(%{"categories" => [%{"id" => "x", "terms" => "nope"}]})

      assert_raise ArgumentError,
                   "terms on category \"x\" in lexicon must be an array, got: \"nope\"",
                   fn -> Lexicon.build(raw) end
    end

    test "raises when an entry is not a string" do
      raw = structured(%{"categories" => [%{"id" => "x", "terms" => [1, 2]}]})

      assert_raise ArgumentError, "lexicon entries must be strings, got: 1", fn ->
        Lexicon.build(raw)
      end
    end

    test "raises when an entry normalizes away to nothing" do
      raw = structured(%{"categories" => [%{"id" => "x", "terms" => ["   "]}]})

      assert_raise ArgumentError,
                   "entry \"   \" in category \"x\" of lexicon normalizes to nothing; " <>
                     "check for stray punctuation",
                   fn -> Lexicon.build(raw) end
    end

    test "raises when a flat list is empty" do
      assert_raise ArgumentError,
                   "category \"flat_terms\" in lexicon defines no terms or phrases",
                   fn -> Lexicon.build([]) end
    end

    test "raises when a flat list contains a non-string" do
      assert_raise ArgumentError, "lexicon entries must be strings, got: 1", fn ->
        Lexicon.build([1, 2])
      end
    end
  end

  describe "the bundled data disclaimer" do
    test "travels inside the default lexicon's notice field" do
      notice = Lexicon.load().notice

      assert is_binary(notice)
      assert notice =~ "detection patterns and nothing else"
      assert notice =~ "never a verdict about a person or a group"
      assert notice =~ "data/README.md"
    end

    test "is repeated in data/README.md beside the word lists" do
      path = Path.join(Path.dirname(Lexicon.default_path()), "README.md")

      assert File.regular?(path)
      assert File.read!(path) =~ "Read this before you use the bundled data."
    end
  end

  describe "actions/0 and severities/0" do
    test "are ordered from least to most severe" do
      assert Lexicon.actions() == [:allow, :flag, :review, :reject]
      assert Lexicon.severities() == [:low, :medium, :high]
    end
  end
end
