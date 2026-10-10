defmodule KinyarwandaModeration.MatcherTest do
  # `install/1` and `clear/0` write to :persistent_term, which is process-wide,
  # so this module must not run concurrently with other modules that use the
  # globally installed matcher.
  use ExUnit.Case, async: false

  alias KinyarwandaModeration.{Lexicon, Matcher}

  doctest KinyarwandaModeration.Matcher

  @raw %{
    "version" => "9.9.9",
    "locale" => "rw",
    "normalization" => %{
      "fold_l_r" => true,
      "strip_prefixes" => true,
      "collapse_repeats" => true,
      "strip_diacritics" => true
    },
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

  defp matcher(raw \\ @raw), do: raw |> Lexicon.build() |> Matcher.compile()

  describe "compile/1" do
    test "carries the lexicon's identity and normalization into the matcher" do
      m = matcher()

      assert m.lexicon_version == "9.9.9"
      assert m.locale == "rw"
      assert m.normalization == Lexicon.build(@raw).normalization
      assert m.normalization.fold_l_r
      assert m.node_count == 6
      assert Matcher.node_count(m) == 6
    end

    test "counts one node per distinct token, plus the root" do
      raw = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "normalization" => %{"strip_prefixes" => false},
        "categories" => [%{"id" => "x", "terms" => ["ab"]}]
      }

      assert matcher(raw).node_count == 2
    end
  end

  describe "scan/2" do
    test "returns the entry, its position and its span for a single token hit" do
      assert [hit] = Matcher.scan(matcher(), ["badterm"])

      assert hit.entry_index == 0
      assert hit.start_token == 0
      assert hit.end_token == 0
      assert hit.entry.term == "badterm"
      assert hit.entry.tokens == ["badterm"]
      assert hit.entry.action == :reject
      assert hit.entry.severity == :high
      assert hit.entry.term_count == 1
      assert hit.entry.category_id == "a"
      assert hit.entry.category_label == "Alpha"
    end

    test "returns nothing for empty input" do
      assert Matcher.scan(matcher(), []) == []
    end

    test "finds every hit in one pass" do
      tokens = ["badterm", "secondterm", "and", "mildterm"]

      assert Matcher.scan(matcher(), tokens)
             |> Enum.map(&{&1.entry.term, &1.start_token, &1.end_token})
             |> Enum.sort() ==
               [
                 {"badterm", 0, 0},
                 {"badterm secondterm", 0, 1},
                 {"mildterm", 3, 3}
               ]
    end

    test "does not match a phrase across a token boundary" do
      m = matcher()

      assert Matcher.scan(m, ["badtermx", "secondterm"]) == []
      assert Matcher.scan(m, ["badtermxsecondterm"]) == []
    end

    test "matches a phrase only when its tokens are adjacent and in order" do
      m = matcher()

      # "badterm" alone still matches, but the phrase does not fire in reverse
      assert Matcher.scan(m, ["secondterm", "badterm"]) |> Enum.map(& &1.entry.term) == [
               "badterm"
             ]

      assert Matcher.scan(m, ["badterm", "secondterm"]) |> Enum.map(& &1.entry.term) ==
               ["badterm", "badterm secondterm"]
    end

    test "reaches a lexicon root through an inflected form" do
      raw = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "normalization" => %{"strip_prefixes" => true},
        "categories" => [%{"id" => "x", "terms" => ["deputa"], "action" => "reject"}]
      }

      m = matcher(raw)

      assert Matcher.scan(m, ["abadeputa"]) |> Enum.map(& &1.entry.term) == ["deputa"]
      assert Matcher.scan(m, ["deputa"]) |> Enum.map(& &1.entry.term) == ["deputa"]
    end

    test "folds l and r when the lexicon asks for it" do
      base = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "categories" => [%{"id" => "x", "terms" => ["igiculu"], "action" => "reject"}]
      }

      folded = matcher(Map.put(base, "normalization", %{"fold_l_r" => true}))
      exact = matcher(Map.put(base, "normalization", %{"fold_l_r" => false}))

      assert Matcher.scan(folded, ["igicuru"]) |> Enum.map(& &1.entry.term) == ["igiculu"]
      assert Matcher.scan(exact, ["igicuru"]) == []
      assert Matcher.scan(exact, ["igiculu"]) |> Enum.map(& &1.entry.term) == ["igiculu"]
    end

    test "flags an l/r variant even when the text itself is not folded" do
      raw = %{
        "version" => "1.0.0",
        "locale" => "rw",
        "normalization" => %{"fold_l_r" => true},
        "categories" => [%{"id" => "x", "terms" => ["igiculu"], "action" => "reject"}]
      }

      assert Matcher.scan(matcher(raw), ["igicuru"]) |> length() == 1
    end
  end

  describe "install/1, current/0 and clear/0" do
    setup do
      Matcher.clear()
      # the suite's baseline is the bundled lexicon, so restore it afterwards
      on_exit(fn -> KinyarwandaModeration.reload(:default) end)
      :ok
    end

    test "returns nil before anything is installed" do
      assert Matcher.current() == nil
    end

    test "makes the matcher readable from any process" do
      m = matcher()
      assert Matcher.install(m) == :ok
      assert Matcher.current() == m

      task = Task.async(fn -> Matcher.current() end)
      assert Task.await(task) == m
    end

    test "clear/0 removes it" do
      :ok = Matcher.install(matcher())
      assert Matcher.clear() == :ok
      assert Matcher.current() == nil
      assert Matcher.clear() == :ok
    end
  end

  describe "expansion/2" do
    test "returns every prefix-stripped reading of a phrase" do
      normalization = %{
        fold_l_r: true,
        strip_prefixes: true,
        collapse_repeats: true,
        strip_diacritics: true
      }

      assert Matcher.expansion(["abadeputa", "yego"], normalization) ==
               [["abadeputa", "yego"], ["deputa", "yego"]]

      assert Matcher.expansion(["yego"], normalization) == [["yego"]]
      assert Matcher.expansion([], normalization) == [[]]
    end

    test "expands nothing when prefix stripping is off" do
      normalization = %{
        fold_l_r: true,
        strip_prefixes: false,
        collapse_repeats: true,
        strip_diacritics: true
      }

      assert Matcher.expansion(["abadeputa"], normalization) == [["abadeputa"]]
    end
  end
end
