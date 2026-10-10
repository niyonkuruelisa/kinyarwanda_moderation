defmodule KinyarwandaModeration.NormalizerTest do
  use ExUnit.Case, async: true

  alias KinyarwandaModeration.Normalizer

  doctest KinyarwandaModeration.Normalizer

  describe "defaults/0" do
    test "enables every rule" do
      assert Normalizer.defaults() == %{
               fold_l_r: true,
               strip_diacritics: true,
               collapse_repeats: true,
               strip_prefixes: true
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
      assert Normalizer.normalize("amaaani") == "amani"
      assert Normalizer.normalize("Gooood") == "god"
      assert Normalizer.normalize("amaaani", collapse_repeats: false) == "amaaani"
    end

    test "leaves a doubled letter alone because vowel length is meaningful" do
      assert Normalizer.normalize("Good") == "good"
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
    test "returns the token itself first, then its noun-class stems" do
      assert Normalizer.variants("abadeputa") == ["abadeputa", "deputa"]
      assert Normalizer.variants("umunyarwanda") == ["umunyarwanda", "nyarwanda"]
    end

    test "returns just the token when there is no stem" do
      assert Normalizer.variants("yego") == ["yego"]
    end

    test "can be told to skip prefix stripping" do
      assert Normalizer.variants("abadeputa", strip_prefixes: false) == ["abadeputa"]
      assert Normalizer.variants("abadeputa", %{"strip_prefixes" => false}) == ["abadeputa"]
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
