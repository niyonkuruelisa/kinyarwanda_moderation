defmodule KinyarwandaModeration.JSONTest do
  use ExUnit.Case, async: true

  alias KinyarwandaModeration.JSON

  doctest KinyarwandaModeration.JSON

  describe "backend/0" do
    test "reports which decoder is in use" do
      assert JSON.backend() in [:erlang_json, :jason]
    end

    test "prefers the decoder built into the runtime" do
      # OTP 27 ships :json, so the dependency-free path is the expected default.
      assert JSON.backend() == :erlang_json
    end
  end

  describe "decode!/1" do
    test "decodes the shapes a lexicon file uses" do
      assert JSON.decode!("[\"a\", \"b\"]") == ["a", "b"]
      assert JSON.decode!("{\"version\": \"1.0.0\"}") == %{"version" => "1.0.0"}
      assert JSON.decode!("[]") == []
      assert JSON.decode!("{}") == %{}
    end

    test "decodes numbers, booleans and nested structures" do
      assert JSON.decode!("[1, 2.5, true, false, null]") == [1, 2.5, true, false, :null]

      assert JSON.decode!("{\"categories\": [{\"id\": \"x\"}]}") == %{
               "categories" => [%{"id" => "x"}]
             }
    end

    test "preserves non-ASCII text" do
      assert JSON.decode!(~s(["café", "igicuru"])) == ["café", "igicuru"]
    end

    test "raises on broken JSON" do
      assert_raise ErlangError, fn -> JSON.decode!("{") end
    end

    test "raises when handed something that is not a binary" do
      assert_raise FunctionClauseError, fn -> JSON.decode!(:not_a_binary) end
    end
  end
end
