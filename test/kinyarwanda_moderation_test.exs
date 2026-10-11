defmodule KinyarwandaModerationTest do
  # Everything here reads or writes the process-wide installed matcher
  # (:persistent_term), so it must run serially.
  use ExUnit.Case, async: false

  alias KinyarwandaModeration.{Lexicon, Match, Matcher, Normalizer, Result, Tmp}

  doctest KinyarwandaModeration

  setup_all do
    {:ok, _} = KinyarwandaModeration.reload(:default)
    :ok
  end

  defp built(raw), do: raw |> Lexicon.build() |> Matcher.compile()

  defp actions(matcher, text) do
    result = KinyarwandaModeration.check(text, matcher: matcher)
    {result.action, Enum.map(result.matches, & &1.term)}
  end

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

    test "declares all seven normalizations" do
      assert KinyarwandaModeration.normalization() ==
               %{
                 squash_doubles: true,
                 collapse_repeats: true,
                 fold_l_r: true,
                 strip_diacritics: true,
                 strip_prefixes: true,
                 augment_drop: true,
                 glued_phrases: true
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
      missing = Tmp.missing("absent_moderation_lexicon.json")
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

  describe "real Kinyarwanda sentences" do
    # A word-level matcher cannot see inside a token, so these exercise the two
    # derivations that reconcile a listed word with how writers spell it.
    setup do
      sentences = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "categories" => [
          %{
            "id" => "x",
            "action" => "reject",
            "severity" => "high",
            "terms" => ["ikirofa", "innyo", "cumita"],
            "phrases" => ["kanywe nzobya"]
          }
        ]
      }

      m = built(sentences)

      m_igituba =
        built(
          update_in(sentences, ["categories"], fn [c | _] ->
            [Map.put(c, "terms", ["igituba"])]
          end)
        )

      %{m: m, m_igituba: m_igituba}
    end

    test "flags a term written cleanly", %{m: m} do
      assert KinyarwandaModeration.check("mba mbona uri ikirofa", matcher: m).action == :reject

      assert KinyarwandaModeration.check("kazunguze innyo muziko", matcher: m).action == :reject
    end

    test "flags a word whose augment a locative ate", %{m_igituba: m} do
      assert KinyarwandaModeration.check("nshaka ko uzampa kugituba", matcher: m).action ==
               :reject

      assert KinyarwandaModeration.check("igituba cyane", matcher: m).action == :reject
    end

    test "flags a phrase a writer ran together", %{m: m} do
      assert KinyarwandaModeration.check("kanywenzobya", matcher: m).action == :reject
      assert KinyarwandaModeration.check("KANYWENZOBYA cyane", matcher: m).action == :reject
      assert KinyarwandaModeration.check("kanywe nzobya", matcher: m).action == :reject
    end

    test "still allows the words that only look like a match", %{m: m, m_igituba: m_igituba} do
      # `nywe nzobya` is two unrelated tokens, not the glued phrase
      assert KinyarwandaModeration.check("nywe nzobya", matcher: m).action == :allow

      # the augment rule never stacks, so a doubled prefix stays clean
      assert KinyarwandaModeration.check("ndigigituba", matcher: m_igituba).action == :allow
    end

    test "reports the span and term for a glued-phrase hit", %{m: m} do
      result = KinyarwandaModeration.check("kanywenzobya cyane", matcher: m)

      assert [match] = result.matches
      assert match.term == "kanywenzobya"
      assert match.tokens == ["kanywenzobya"]
      assert match.term_count == 1
      assert match.byte_offset == 0
      assert match.byte_length == 12
      assert match.token_offset == 0
      assert match.category_id == "x"
      assert match.action == :reject
    end

    test "reports the listed word, not the inflected one, for an augment hit", %{
      m_igituba: m
    } do
      result = KinyarwandaModeration.check("nshaka ko uzampa kugituba", matcher: m)

      assert [match] = result.matches
      assert match.term == "igituba"
      assert match.token_offset == 3
      assert match.byte_offset == 17
      assert match.byte_length == 8
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

  describe "regressions" do
    @describetag :regression

    # Each case here is either a bug that shipped once, or a derivation boundary
    # that a later change could quietly move. Near-misses that must stay clean
    # are asserted next to every hit on purpose.

    setup do
      lexicon = fn terms, phrases ->
        %{
          "version" => "1.0.0",
          "locale" => "rw",
          "categories" => [
            %{
              "id" => "x",
              "action" => "reject",
              "severity" => "high",
              "terms" => terms,
              "phrases" => phrases
            }
          ]
        }
      end

      %{
        m: built(lexicon.(["cumita", "igituba", "kora"], ["kanywe nzobya"])),
        m_igituba: built(lexicon.(["igituba"], []))
      }
    end

    test "the augment rule never stacks, so a doubled prefix stays clean", %{m_igituba: m} do
      # Bug: an earlier version kept stripping augments, so `ndigigituba`
      # reached the stem and rejected a clean sentence.
      assert actions(m, "kugituba") == {:reject, ["igituba"]}
      assert actions(m, "ndigigituba") == {:allow, []}
      assert actions(m, "igitubatiguba") == {:allow, []}
    end

    test "a prefix inside a token is not a prefix", %{m: m} do
      # Known limitation: the matcher works on whole tokens, so it cannot see a
      # noun-class prefix that is glued to a preceding syllable. Pinned so that
      # widening the matcher to find these is a deliberate change.
      assert actions(m, "uyumucumita") == {:allow, []}
      assert actions(m, "ndakumucumita") == {:allow, []}
    end

    test "a glued phrase does not make its unrelated words toxic", %{m: m} do
      # Bug: the glued variant of "kanywe nzobya" once matched "nywe nzobya",
      # which is two unrelated tokens.
      assert actions(m, "kanywenzobya") == {:reject, ["kanywenzobya"]}
      assert actions(m, "nywe nzobya") == {:allow, []}
    end

    test "stems expand to the noun classes but stop at the word", %{m: m} do
      # Bug: stem expansion once ran past the token, so an unrelated word that
      # merely started with the stem was flagged.
      assert actions(m, "gukora") == {:reject, ["kora"]}
      assert actions(m, "umukora") == {:reject, ["kora"]}
      assert actions(m, "gukorana") == {:allow, []}
      assert actions(m, "kora2") == {:allow, []}
    end

    test "an unrelated sentence stays clean", %{m: m} do
      assert actions(m, "all good here") == {:allow, []}
    end

    test "padding a listed word with a doubled letter does not evade the match", %{m_igituba: m} do
      # Bug: the repeat rule only collapsed runs of three or more, so a single
      # doubled letter walked straight past it. Every position is covered.
      assert actions(m, "igituba") == {:reject, ["igituba"]}
      assert actions(m, "igiituba") == {:reject, ["igituba"]}
      assert actions(m, "igituuba") == {:reject, ["igituba"]}
      assert actions(m, "igitubba") == {:reject, ["igituba"]}
      assert actions(m, "igitubaa") == {:reject, ["igituba"]}
      assert actions(m, "igiiituuba") == {:reject, ["igituba"]}
      assert actions(m, "IGIITUBA") == {:reject, ["igituba"]}

      # Padding on a word that is not listed must not become toxic.
      assert actions(m, "igikubo") == {:allow, []}
    end

    test "padding survives a prefix, so the augment rule still reaches the stem", %{m: m} do
      # The padded token has to be squashed before the augment is dropped or the
      # stem comes out as "giituba", which matches nothing.
      assert actions(m, "kugiituba") == {:reject, ["igituba"]}
      assert actions(m, "kugituuba") == {:reject, ["igituba"]}
    end

    test "squashing is symmetric, so a listed long vowel still matches" do
      # The lexicon side is squashed too, which is what keeps this working once
      # "amaani" normalizes onto "amani".
      l =
        built(%{
          "version" => "1.0.0",
          "locale" => "rw",
          "categories" => [%{"id" => "x", "action" => "reject", "terms" => ["amaani"]}]
        })

      assert actions(l, "amaani") == {:reject, ["amaani"]}
      assert actions(l, "amani") == {:reject, ["amaani"]}
      assert actions(l, "amaaani") == {:reject, ["amaani"]}
    end

    test "the legitimate nny class is squashed along with everything else" do
      # `innyo` is real Kinyarwanda orthography and the only doubled-letter term
      # in the shipped lexicon. It is deliberately not exempted: `nny` is just
      # `n` plus the `ny` digraph, so an exemption would be the same edit that
      # lets doubled-`n` padding through. Because the lexicon side is squashed
      # identically, the term stays matched in every spelling.
      l =
        built(%{
          "version" => "1.0.0",
          "locale" => "rw",
          "categories" => [
            %{"id" => "x", "action" => "reject", "terms" => ["innyo", "ubunnyano"]}
          ]
        })

      assert actions(l, "innyo") == {:reject, ["innyo"]}
      assert actions(l, "inyo") == {:reject, ["innyo"]}
      assert actions(l, "innnyo") == {:reject, ["innyo"]}
      assert actions(l, "innyoo") == {:reject, ["innyo"]}

      # Words outside the lexicon are unaffected, whether or not they carry nny.
      assert actions(l, "ubunnyano") == {:reject, ["ubunnyano"]}
      assert actions(l, "abakinnyi") == {:allow, []}
      assert actions(l, "kannyye") == {:allow, []}
    end

    test "padding a ny with an extra n does not evade a listed word", %{m: m} do
      # The squash is what catches this. Guarding `nny` to protect `innyo` would
      # reopen the hole, which is why there is no guard. The builder derives a
      # pre-glued entry from the phrase, and that is the one reported here.
      assert actions(m, "kanywe nzobya") == {:reject, ["kanywe nzobya"]}
      assert actions(m, "kanywenzobya") == {:reject, ["kanywenzobya"]}
      assert actions(m, "kannywenzobya") == {:reject, ["kanywenzobya"]}
      assert actions(m, "kannnywenzobya") == {:reject, ["kanywenzobya"]}

      # Neither half of the phrase is a term on its own.
      assert actions(m, "kanywe") == {:allow, []}
      assert actions(m, "nzobya") == {:allow, []}
    end

    test "folds l and r in both directions, not just one" do
      # The fold is one way (l becomes r), so a term may be listed with either
      # letter and still catch the other spelling. Both directions are asserted
      # because a one-way fold is easy to get wrong in a way that only shows on
      # one side, and the user asked for this to be guaranteed rather than
      # accidental.
      r_term =
        built(%{
          "version" => "1.0.0",
          "locale" => "rw",
          "categories" => [%{"id" => "x", "action" => "reject", "terms" => ["gaswere"]}]
        })

      l_term =
        built(%{
          "version" => "1.0.0",
          "locale" => "rw",
          "categories" => [%{"id" => "x", "action" => "reject", "terms" => ["gaswele"]}]
        })

      # A term listed with r catches every l spelling of the same word.
      for spelling <- ~w(gaswere gaswele gaswelle gaswelre gaswerle) do
        assert actions(r_term, spelling) == {:reject, ["gaswere"]}
      end

      # A term listed with l catches every r spelling of the same word.
      for spelling <- ~w(gaswele gaswere gaswerre gaswelre gaswerle gaswelle) do
        assert actions(l_term, spelling) == {:reject, ["gaswele"]}
      end

      # Nearby words and truncations stay clean in both directions.
      for spelling <- ~w(gase gasegase igase amase gasana isaso gaswer gaswel) do
        assert actions(r_term, spelling) == {:allow, []}
        assert actions(l_term, spelling) == {:allow, []}
      end
    end

    test "does not fold a hate word onto a near-spelled innocent word" do
      # `igicucu` is a listed hate word, `igicuru` is not. The fold only turns
      # l into r and `igicucu` has no l, so the two stay separate tokens. If
      # folding were two way, listing `igicucu` would also condemn `igicuru`.
      # The innocent spellings must stay clean, and the padded hate spelling
      # must still be caught.
      l =
        built(%{
          "version" => "1.0.0",
          "locale" => "rw",
          "categories" => [%{"id" => "x", "action" => "reject", "terms" => ["igicucu"]}]
        })

      assert actions(l, "igicucu") == {:reject, ["igicucu"]}
      assert actions(l, "igicucuu") == {:reject, ["igicucu"]}

      # Every spelling that folds onto `igicuru` instead stays clean.
      for innocent <- ~w(igicuru igiculu igicuruu igiculuu) do
        assert actions(l, innocent) == {:allow, []}
      end
    end

    test "normalizing twice changes nothing" do
      # fold_l_r rewrites l to r, so running it after the squashes could leave a
      # fresh doubled letter behind and make a second pass differ from the first
      # (`gaswelre` -> `gaswerre` -> `gaswere`). Fold first and the output is
      # already closed under every rule, so a second pass is a no-op.
      for text <- ~w(gaswelre gaswerle gaswelle gaswere lr lrl rlr amaani igiituba) do
        once = Normalizer.normalize(text)
        assert Normalizer.normalize(once) == once
      end

      # variants/2 is the matcher's own path, so it has to agree with normalize/2.
      for text <- ~w(gaswelre gaswerle gaswelle abadeputa igiituba amaani) do
        variants = Normalizer.variants(text)
        assert Normalizer.normalize(text) in variants
        assert Enum.all?(variants, &(Normalizer.normalize(&1) == &1))
      end
    end
  end
end
