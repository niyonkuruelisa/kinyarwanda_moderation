defmodule KinyarwandaModerationTest do
  # Everything here reads or writes the process-wide installed matcher
  # (:persistent_term), so it must run serially.
  use ExUnit.Case, async: false

  alias KinyarwandaModeration.{Lexicon, Match, Matcher, Result}

  doctest KinyarwandaModeration

  setup_all do
    {:ok, _} = KinyarwandaModeration.reload(:default)
    :ok
  end

  defp built(raw), do: raw |> Lexicon.build() |> Matcher.compile()

  @mild %{
    "version" => "1.0.0",
    "locale" => "rw",
    "categories" => [
      %{
        "id" => "b",
        "label" => "Beta",
        "severity" => "low",
        "action" => "flag",
        "terms" => ["mildterm"]
      }
    ]
  }

  @pair %{
    "version" => "1.0.0",
    "locale" => "rw",
    "categories" => [
      %{
        "id" => "a",
        "label" => "Alpha",
        "severity" => "high",
        "action" => "reject",
        "terms" => ["badterm"],
        "phrases" => ["badterm secondterm"]
      },
      %{
        "id" => "b",
        "label" => "Beta",
        "severity" => "low",
        "action" => "flag",
        "terms" => ["mildterm"]
      }
    ]
  }

  describe "the bundled lexicon" do
    test "is installed at boot" do
      assert %Matcher{} = KinyarwandaModeration.matcher()
      assert KinyarwandaModeration.lexicon_version() == "0.1.0"
    end

    test "declares all four normalizations" do
      assert KinyarwandaModeration.normalization() ==
               %{
                 collapse_repeats: true,
                 fold_l_r: true,
                 strip_diacritics: true,
                 strip_prefixes: true
               }
    end

    test "normalizes text the way the lexicon asks" do
      assert KinyarwandaModeration.normalize("IgiCULU") == "igicuru"
    end

    test "flags a phrase and a single term" do
      assert KinyarwandaModeration.toxic?("demoviolence demothreat")
      assert KinyarwandaModeration.toxic?("hey DEMOVIOLENCE you")
      assert KinyarwandaModeration.toxic?("demoinsult")
    end

    test "allows ordinary text" do
      refute KinyarwandaModeration.toxic?("all good here")
      assert KinyarwandaModeration.check("hello world").action == :allow
    end

    test "reports the worst action and severity across matches" do
      result = KinyarwandaModeration.check("demoviolence demothreat and demoinsult")

      assert result.action == :reject
      assert result.severity == :high
      assert Result.category_ids(result) == ["demo_violence", "demo_insult"]
      assert result.lexicon_version == "0.1.0"
    end

    test "lists where a lexicon could be loaded from" do
      sources = KinyarwandaModeration.lexicon_sources()

      assert Enum.all?(sources, &is_binary/1)
      assert "rw_lexicon.json" in Enum.map(sources, &Path.basename/1)
    end
  end

  describe "check/2 without a matcher" do
    test "returns a benign result for nil" do
      result = KinyarwandaModeration.check(nil)

      assert result.text == ""
      assert result.action == :allow
      assert result.severity == nil
      assert result.matches == []
    end

    test "returns a benign result for empty and clean input" do
      assert KinyarwandaModeration.check("").action == :allow
      assert KinyarwandaModeration.check("").normalized == ""
      assert KinyarwandaModeration.check("nothing here").matches == []
    end

    test "reports the installed lexicon version" do
      assert KinyarwandaModeration.check("nothing here").lexicon_version == "0.1.0"
    end
  end

  describe "the :matcher option" do
    test "scans with an explicitly passed matcher" do
      m = built(@pair)
      result = KinyarwandaModeration.check("a badterm secondterm and mildterm here", matcher: m)

      assert result.action == :reject
      assert result.severity == :high
      assert result.lexicon_version == "1.0.0"

      assert result.matches
             |> Enum.map(&{&1.term, &1.token_offset, &1.byte_offset, &1.byte_length}) ==
               [{"badterm", 1, 2, 7}, {"badterm secondterm", 1, 2, 18}, {"mildterm", 4, 25, 8}]
    end

    test "accepts the map form of the options" do
      m = built(@mild)
      assert KinyarwandaModeration.check("mildterm", %{matcher: m}).action == :flag
    end

    test "enforces token boundaries for phrases" do
      m = built(@pair)

      assert KinyarwandaModeration.check("badtermX secondterm", matcher: m).matches == []
      assert KinyarwandaModeration.check("badtermXsecondterm", matcher: m).matches == []
    end

    test "reaches a lexicon root through a prefixed form" do
      raw = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "categories" => [%{"id" => "x", "terms" => ["deputa"], "action" => "reject"}]
      }

      m = built(raw)

      assert KinyarwandaModeration.check("abadeputa", matcher: m).action == :reject

      assert KinyarwandaModeration.check("abadeputa", matcher: m).matches |> Enum.map(& &1.term) ==
               ["deputa"]

      assert KinyarwandaModeration.check("deputa", matcher: m).action == :reject
    end

    test "folds l and r only when the lexicon asks for it" do
      base = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "categories" => [%{"id" => "x", "terms" => ["igiculu"], "action" => "reject"}]
      }

      folded = built(Map.put(base, "normalization", %{"fold_l_r" => true}))
      exact = built(Map.put(base, "normalization", %{"fold_l_r" => false}))

      assert KinyarwandaModeration.check("igicuru", matcher: folded).action == :reject
      assert KinyarwandaModeration.check("igicuru", matcher: exact).action == :allow
      assert KinyarwandaModeration.check("igiculu", matcher: exact).action == :reject
    end

    test "falls back to the installed matcher when no match option is given" do
      assert KinyarwandaModeration.check("demoinsult").action == :flag
      assert KinyarwandaModeration.check("demoinsult", []).action == :flag
    end
  end

  describe "the :lexicon option" do
    test "compiles the lexicon on the fly" do
      raw = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "categories" => [%{"id" => "x", "action" => "reject", "terms" => ["zzz"]}]
      }

      result = KinyarwandaModeration.check("zzz here", lexicon: Lexicon.build(raw))

      assert result.action == :reject
      assert result.lexicon_version == "1.0.0"
    end

    test "accepts the map form of the options" do
      raw = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "categories" => [%{"id" => "x", "action" => "reject", "terms" => ["zzz"]}]
      }

      assert KinyarwandaModeration.check("zzz here", %{lexicon: Lexicon.build(raw)}).action ==
               :reject
    end
  end

  describe "redaction" do
    setup do
      %{matcher: built(@mild)}
    end

    test "is off unless asked for", %{matcher: m} do
      assert KinyarwandaModeration.check("mildterm", matcher: m).redacted == nil
    end

    test "replaces a single match", %{matcher: m} do
      assert KinyarwandaModeration.check("mildterm", matcher: m, redact?: true).redacted ==
               "[...]"
    end

    test "replaces every match", %{matcher: m} do
      result = KinyarwandaModeration.check("mildterm then mildterm", matcher: m, redact?: true)
      assert result.redacted == "[...] then [...]"

      result = KinyarwandaModeration.check("mildterm mildterm", matcher: m, redact?: true)
      assert result.redacted == "[...] [...]"
    end

    test "keeps the text around the match", %{matcher: m} do
      assert KinyarwandaModeration.check("x mildterm y", matcher: m, redact?: true).redacted ==
               "x [...] y"

      assert KinyarwandaModeration.check("a mildterm, b mildterm! c", matcher: m, redact?: true).redacted ==
               "a [...], b [...]! c"
    end

    test "covers the bytes the user actually typed", %{matcher: m} do
      assert KinyarwandaModeration.check("MILDTERM", matcher: m, redact?: true).redacted ==
               "[...]"
    end

    test "leaves text that only looks similar alone", %{matcher: m} do
      assert KinyarwandaModeration.check("abadmildterm", matcher: m, redact?: true).redacted ==
               "abadmildterm"

      assert KinyarwandaModeration.check("worthless", matcher: m, redact?: true).redacted ==
               "worthless"
    end

    test "accepts a custom replacement", %{matcher: m} do
      result =
        KinyarwandaModeration.check("mildterm", matcher: m, redact?: true, replacement: "###")

      assert result.redacted == "###"

      result = KinyarwandaModeration.check("mildterm", matcher: m, replacement: "")
      assert result.redacted == nil

      result =
        KinyarwandaModeration.check("x mildterm", matcher: m, redact?: true, replacement: "")

      assert result.redacted == "x "
    end

    test "accepts the redact: alias without a question mark", %{matcher: m} do
      assert KinyarwandaModeration.check("mildterm", matcher: m, redact: true).redacted == "[...]"
    end

    test "accepts the map form of the options", %{matcher: m} do
      assert KinyarwandaModeration.check("mildterm", %{matcher: m, redact?: true}).redacted ==
               "[...]"
    end

    test "handles empty input", %{matcher: m} do
      assert KinyarwandaModeration.check("", matcher: m, redact?: true).redacted == ""
    end

    test "collapses overlapping matches into one replacement" do
      m = built(@pair)
      result = KinyarwandaModeration.check("badterm secondterm here", matcher: m, redact?: true)

      assert result.matches |> Enum.map(& &1.term) == ["badterm", "badterm secondterm"]
      assert result.redacted == "[...] here"

      result =
        KinyarwandaModeration.check("badterm secondterm here",
          matcher: m,
          redact?: true,
          replacement: "?"
        )

      assert result.redacted == "? here"
    end
  end

  describe "reload/2 and compile/2" do
    setup do
      on_exit(fn -> KinyarwandaModeration.reload(:default) end)
      :ok
    end

    test "reload/2 installs the bundled lexicon and returns the matcher" do
      assert {:ok, %Matcher{} = m} = KinyarwandaModeration.reload(:default)
      assert m.lexicon_version == "0.1.0"
      assert Matcher.current() == m
    end

    test "reload/2 accepts no argument and installs the default" do
      assert {:ok, %Matcher{}} = KinyarwandaModeration.reload()
      assert KinyarwandaModeration.lexicon_version() == "0.1.0"
    end

    test "reports a missing lexicon as an error rather than raising" do
      missing = Path.join(System.tmp_dir!(), "absent_moderation_lexicon.json")
      refute File.exists?(missing)

      assert {:error, reason} = KinyarwandaModeration.reload(missing)
      assert reason =~ "no lexicon found at"
    end

    test "installs a flat list of terms" do
      assert {:ok, m} = KinyarwandaModeration.compile(["zzterm"])

      assert m.lexicon_version == "0.0.0"
      assert KinyarwandaModeration.check("zzterm").action == :flag
      assert KinyarwandaModeration.check("zzterm").matches |> Enum.map(& &1.term) == ["zzterm"]
    end

    test "installs a structured lexicon map" do
      raw = %{
        "version" => "2.0.0",
        "locale" => "rw",
        "categories" => [
          %{"id" => "x", "action" => "reject", "severity" => "high", "terms" => ["qqterm"]}
        ]
      }

      assert {:ok, m} = KinyarwandaModeration.compile(raw)

      assert m.lexicon_version == "2.0.0"
      assert KinyarwandaModeration.check("qqterm").action == :reject
      assert KinyarwandaModeration.lexicon_version() == "2.0.0"
    end

    test "returns the validation error instead of raising" do
      assert {:error, reason} = KinyarwandaModeration.compile("nope")

      assert reason ==
               "lexicon must decode to a JSON object or an array of terms, got: \"nope\""
    end

    test "accepts normalization overrides when compiling" do
      raw = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "categories" => [%{"id" => "x", "terms" => ["ab"]}]
      }

      assert {:ok, m} = KinyarwandaModeration.compile(raw, strip_prefixes: false)
      assert m.normalization.strip_prefixes == false
    end
  end

  describe "Match" do
    test "exposes the category and the scored span" do
      result = KinyarwandaModeration.check("badterm here", matcher: built(@pair))

      assert [match] = result.matches
      assert match.term == "badterm"
      assert match.tokens == ["badterm"]
      assert match.category_id == "a"
      assert match.category_label == "Alpha"
      assert match.action == :reject
      assert match.severity == :high
      assert match.token_offset == 0
      assert match.term_count == 1
      assert match.byte_offset == 0
      assert match.byte_length == 7
      assert Match.byte_end(match) == 7
    end

    test "spans a whole phrase, including the space between its tokens" do
      result = KinyarwandaModeration.check("say badterm secondterm", matcher: built(@pair))
      phrase = Enum.find(result.matches, &(&1.term_count == 2))

      assert phrase.term == "badterm secondterm"
      assert phrase.byte_offset == 4
      assert phrase.byte_length == 18
      assert phrase.token_offset == 1
    end
  end
end
