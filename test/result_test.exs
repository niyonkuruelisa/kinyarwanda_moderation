defmodule KinyarwandaModeration.ResultTest do
  use ExUnit.Case, async: false

  alias KinyarwandaModeration.{Lexicon, Matcher, Match, Result}

  doctest KinyarwandaModeration.Result

  @raw %{
    "version" => "9.9.9",
    "locale" => "rw",
    "normalization" => %{"fold_l_r" => true, "strip_prefixes" => true},
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

  setup_all do
    %{matcher: @raw |> Lexicon.build() |> Matcher.compile()}
  end

  describe "toxic?/1 and count/1" do
    test "a clean result is not toxic and has no matches", %{matcher: m} do
      result = KinyarwandaModeration.check("nothing to see here", matcher: m)

      refute Result.toxic?(result)
      assert Result.count(result) == 0
      assert result.matches == []
      assert Result.category_ids(result) == []
    end

    test "any match makes the result toxic", %{matcher: m} do
      result = KinyarwandaModeration.check("a mildterm here", matcher: m)

      assert Result.toxic?(result)
      assert Result.count(result) == 1
      assert Result.category_ids(result) == ["b"]
    end
  end

  describe "category_ids/1" do
    test "lists distinct categories in order of first appearance", %{matcher: m} do
      result = KinyarwandaModeration.check("badterm then mildterm", matcher: m)
      assert Result.category_ids(result) == ["a", "b"]
    end

    test "does not repeat a category", %{matcher: m} do
      result = KinyarwandaModeration.check("mildterm and mildterm again", matcher: m)
      assert Result.category_ids(result) == ["b"]
      assert Result.count(result) == 2
    end
  end

  describe "to_map/1" do
    test "exposes a flat, JSON-friendly verdict", %{matcher: m} do
      map = KinyarwandaModeration.check("badterm secondterm here", matcher: m) |> Result.to_map()

      assert Map.keys(map) |> Enum.sort() ==
               [:action, :categories, :count, :matches, :severity, :toxic]

      assert map.toxic
      assert map.action == :reject
      assert map.severity == :high
      assert map.count == 2
      assert map.categories == ["a"]
    end

    test "describes each match without leaking structs", %{matcher: m} do
      map = KinyarwandaModeration.check("badterm", matcher: m) |> Result.to_map()

      assert [match] = map.matches

      assert Map.keys(match) |> Enum.sort() ==
               [
                 :action,
                 :byte_length,
                 :byte_offset,
                 :category,
                 :severity,
                 :term,
                 :term_count,
                 :token_offset
               ]

      assert match.term == "badterm"
      assert match.category == "a"
      assert match.action == :reject
      assert match.severity == :high
      assert match.token_offset == 0
      assert match.term_count == 1
      assert match.byte_offset == 0
      assert match.byte_length == 7
    end

    test "a clean verdict serializes to primitives", %{matcher: m} do
      map = KinyarwandaModeration.check("all good", matcher: m) |> Result.to_map()

      refute map.toxic
      assert map.action == :allow
      assert map.severity == nil
      assert map.count == 0
      assert map.categories == []
      assert map.matches == []
    end
  end

  describe "Match.byte_end/1" do
    test "is exclusive", %{matcher: m} do
      [match] = KinyarwandaModeration.check("go badterm!", matcher: m).matches

      assert match.byte_offset == 3
      assert match.byte_length == 7
      assert Match.byte_end(match) == 10
    end
  end
end
