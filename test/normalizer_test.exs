defmodule KinyarwandaModeration.NormalizerTest do
  use ExUnit.Case, async: true

  alias KinyarwandaModeration.Normalizer

  doctest KinyarwandaModeration.Normalizer

  describe "defaults/0" do
    test "enables every rule" do
      assert Normalizer.defaults() == %{
               fold_l_r: true,
               strip_diacritics: true,
               squash_doubles: true,
               collapse_repeats: true,
               strip_prefixes: true,
               augment_drop: true,
               glued_phrases: true
             }
    end
  end

  describe "normalize/2" do
    test "lowercases and trims" do
      assert Normalizer.normalize("  IgiCULU ") == "igicuru"
    end

    test "folds l onto r, and off on request" do
      assert Normalizer.normalize("igiculu") == "igicuru"
      assert Normalizer.normalize("igiculu", fold_l_r: false) == "igiculu"
      assert Normalizer.normalize("  IgiCULU ", fold_l_r: false) == "igiculu"
    end

    test "strips diacritics, and keeps them on request" do
      assert Normalizer.normalize("café èàü") == "cafe eau"
      assert Normalizer.normalize("café", strip_diacritics: false) == "café"
    end

    test "collapses runs of three or more identical letters" do
      assert Normalizer.normalize("Gooood") == "god"
      assert Normalizer.normalize("amaaani") == "amani"
    end

    test "collapse_repeats is independently switchable" do
      # Subsumed by squash_doubles for letters, so it is only observable on its
      # own: it kills the three-letter run but keeps the meaningful long vowel.
      assert Normalizer.normalize("amaaani", squash_doubles: false) == "amani"
      assert Normalizer.normalize("amaani", squash_doubles: false) == "amaani"

      assert Normalizer.normalize("amaaani", squash_doubles: false, collapse_repeats: false) ==
               "amaaani"
    end

    test "squashes a doubled letter so padding cannot evade a match" do
      assert Normalizer.normalize("igiituba") == "igituba"
      assert Normalizer.normalize("igituuba") == "igituba"
      assert Normalizer.normalize("igitubba") == "igituba"
      assert Normalizer.normalize("Good") == "god"
    end

    test "squashing also merges long-vowel spellings, and is switchable" do
      # Accepted: the merged spelling only matters if the short form is itself
      # listed, and the lexicon is squashed the same way, so both still match.
      assert Normalizer.normalize("amaani") == "amani"
      assert Normalizer.normalize("kuubona") == "kubona"

      assert Normalizer.normalize("amaani", squash_doubles: false) == "amaani"
      assert Normalizer.normalize("igiituba", squash_doubles: false) == "igiituba"
    end

    test "collapses whitespace" do
      assert Normalizer.normalize("a   b") == "a b"
    end

    test "folds typographic apostrophes onto the ASCII one" do
      assert Normalizer.normalize("\u02bcyego\u02bc") == "'yego'"
      assert Normalizer.normalize("\u2018yego\u2019") == "'yego'"
      assert Normalizer.normalize("\u2032yego\u2032") == "'yego'"
    end

    test "accepts string-keyed options, the shape a lexicon file uses" do
      assert Normalizer.normalize("igiculu", %{"fold_l_r" => false}) == "igiculu"
    end
  end

  describe "tokens/2" do
    test "normalizes and splits on punctuation" do
      assert Normalizer.tokens("Amaaani, yego!") == ["amani", "yego"]
      assert Normalizer.tokens("Yego, IgiCULU!") == ["yego", "igicuru"]
    end

    test "keeps an apostrophe inside a word" do
      assert Normalizer.tokens("abana'bana") == ["abana'bana"]
    end

    test "returns nothing for punctuation-only input" do
      assert Normalizer.tokens("   ") == []
      assert Normalizer.tokens("!!!") == []
    end
  end

  describe "tokenize/2" do
    test "reports offsets into the original, unnormalized text" do
      assert Normalizer.tokenize("Yego, IgiCULU!") == [{"yego", 0, 4}, {"igicuru", 6, 7}]
    end

    test "counts bytes rather than characters" do
      assert Normalizer.tokenize("café yego") == [{"cafe", 0, 5}, {"yego", 6, 4}]
    end

    test "trims wrapped apostrophes and adjusts the offset" do
      assert Normalizer.tokenize("'yego'") == [{"yego", 1, 4}]
      assert Normalizer.tokenize("\u02bcyego\u02bc") == [{"yego", 2, 4}]
      assert Normalizer.tokenize("\u2018yego\u2019") == [{"yego", 3, 4}]
      assert Normalizer.tokenize("\u2032yego\u2032") == [{"yego", 3, 4}]
    end

    test "keeps an interior apostrophe and its span" do
      assert Normalizer.tokenize("aba\u02bcnabana") == [{"aba'nabana", 0, 11}]
    end

    test "returns nothing for blank input" do
      assert Normalizer.tokenize("   ") == []
    end
  end

  describe "variants/2" do
    test "returns the token itself first, then its noun-class stems and augment drop" do
      assert Normalizer.variants("abadeputa") == ["abadeputa", "deputa", "badeputa"]
      assert Normalizer.variants("umunyarwanda") == ["umunyarwanda", "nyarwanda", "munyarwanda"]
    end

    test "returns just the token when there is no stem" do
      assert Normalizer.variants("yego") == ["yego"]
    end

    test "adds the augment-dropped form a locative or verb leaves behind" do
      assert Normalizer.variants("igituba") == ["igituba", "gituba"]
      assert Normalizer.variants("igituba", augment_drop: false) == ["igituba"]
    end

    test "meets prefix stripping in the middle" do
      # `ku` is a noun-class prefix, so the input side reaches `gituba` by
      # stripping it - which is the same form augment dropping gives the entry
      # `igituba`. Neither rule alone closes that gap.
      assert Normalizer.variants("kugituba") == ["kugituba", "gituba"]
      assert Normalizer.variants("kugituba", strip_prefixes: false) == ["kugituba"]
      assert Normalizer.variants("kugituba", augment_drop: false) == ["kugituba", "gituba"]
    end

    test "can be told to skip prefix stripping" do
      assert Normalizer.variants("abadeputa", strip_prefixes: false) ==
               ["abadeputa", "badeputa"]

      assert Normalizer.variants("abadeputa", %{"strip_prefixes" => false}) ==
               ["abadeputa", "badeputa"]
    end
  end

  describe "stems/1" do
    test "strips a known noun-class prefix" do
      assert Normalizer.stems("abadeputa") == ["deputa"]
    end

    test "never produces a stem shorter than the minimum" do
      assert Normalizer.stems("abana") == []
      assert Normalizer.stems("umu") == []
    end

    test "returns nothing when prefix stripping is off" do
      assert Normalizer.stems("abadeputa", strip_prefixes: false) == []
    end
  end

  describe "augment_dropped/1" do
    test "removes the initial vowel, leaving the class prefix on the stem" do
      assert Normalizer.augment_dropped("igituba") == ["gituba"]
      assert Normalizer.augment_dropped("imboro") == ["mboro"]
    end

    test "returns nothing when the token has no initial-vowel augment" do
      assert Normalizer.augment_dropped("yego") == []
      assert Normalizer.augment_dropped("gituba") == []
    end

    test "never produces a remainder shorter than the minimum" do
      assert Normalizer.augment_dropped("aba") == []
      assert Normalizer.augment_dropped("umu") == []
      assert Normalizer.augment_dropped("umva") == ["mva"]
    end

    test "returns nothing when the rule is off" do
      assert Normalizer.augment_dropped("igituba", augment_drop: false) == []
    end
  end

  describe "effective/1" do
    test "unwraps a nested normalization map, the shape a lexicon declares" do
      assert Normalizer.effective(%{"normalization" => %{"strip_prefixes" => false}}) ==
               %{Normalizer.defaults() | strip_prefixes: false}
    end

    test "accepts a keyword list and string keys" do
      assert Normalizer.effective(normalization: %{"fold_l_r" => false}) ==
               %{Normalizer.defaults() | fold_l_r: false}

      assert Normalizer.effective(%{"fold_l_r" => false}) ==
               %{Normalizer.defaults() | fold_l_r: false}
    end

    test "ignores input that is neither a map nor a keyword list" do
      assert Normalizer.effective(:nope) == Normalizer.defaults()
    end
  end

  describe "resolve/2" do
    test "applies only the keys the caller passed" do
      assert Normalizer.resolve(Normalizer.defaults(), strip_prefixes: false) ==
               %{Normalizer.defaults() | strip_prefixes: false}
    end

    test "merges string-keyed overrides over string-keyed base options" do
      assert Normalizer.resolve(%{"fold_l_r" => false}, %{"collapse_repeats" => false}) ==
               %{Normalizer.defaults() | fold_l_r: false, collapse_repeats: false}
    end

    test "ignores unknown keys from the caller" do
      assert Normalizer.resolve([fold_l_r: true], nope: 1, fold_l_r: false) ==
               %{Normalizer.defaults() | fold_l_r: false}
    end
  end
end
