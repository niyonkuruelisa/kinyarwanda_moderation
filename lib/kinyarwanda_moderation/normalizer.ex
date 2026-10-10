defmodule KinyarwandaModeration.Normalizer do
  @moduledoc """
  Text normalization tuned for Kinyarwanda.

  Generic profanity filters fail on Kinyarwanda for reasons that are specific to
  how the language is written online. This module handles the four that matter
  most:

    * **l / r folding** - Kinyarwanda has no native *l* in most positions, so
      writers frequently swap *l* and *r* for each other
      (`igicucu` / `igiculu`). Both spellings are folded onto *r* before
      comparison.

    * **Diacritic folding** - The standard orthography is unaccented, but users
      type `é`, `á`, `è` and friends anyway. Text is decomposed to NFD and the
      combining marks are dropped.

    * **Repeat collapsing** - Runs of three or more identical letters are
      collapsed to one, which defeats padding such as `amaaani`. Doubled vowels
      that are two letters long are left alone because vowel length is
      meaningful in Kinyarwanda.

    * **Noun-class prefix stripping** - Kinyarwanda nouns inflect heavily by
      prefix (`umu-`, `aba-`, `iki-`, `ibi-`, ...). Matching a root term also
      checks the stems left after removing a known prefix, so inflected forms
      still hit.

  Every rule is individually switchable, either globally through the options
  accepted here or per-lexicon through the `"normalization"` object in
  `priv/data/rw_lexicon.json`.

  ## Examples

      iex> KinyarwandaModeration.Normalizer.normalize("  IgiCULU ")
      "igicuru"

      iex> KinyarwandaModeration.Normalizer.tokens("Amaaani, yego!")
      ["amani", "yego"]

      iex> KinyarwandaModeration.Normalizer.variants("abadeputa")
      ["abadeputa", "deputa"]

  """

  @defaults %{
    fold_l_r: true,
    strip_diacritics: true,
    collapse_repeats: true,
    strip_prefixes: true
  }

  # Option keys as they appear in JSON lexicons, mapped onto their atom form.
  # An explicit table rather than String.to_atom/1 so a lexicon file can never
  # create atoms.
  @option_names Map.merge(
                  Map.new(@defaults, fn {key, _value} -> {Atom.to_string(key), key} end),
                  %{"normalization" => :normalization}
                )

  # Common Kinyarwanda noun-class prefixes. Kept deliberately short: every prefix
  # added here increases recall at the cost of precision, and a stem shorter than
  # @min_stem_length is never produced.
  @noun_class_prefixes ~w(aba abu ba bi gi gu ha ibi iki imi ingi ku ma mu ntu tu ubu ugu uku umu uru utu zi)

  @min_stem_length 3

  @combining_marks ~r/[\p{Mn}\p{Mc}]/u
  @whitespace ~r/\s+/u
  @repeated_letter ~r/(.)\1{2,}/u

  # ASCII apostrophe plus the typographic ones writers actually paste in
  # (U+2018, U+2019, U+02BC, U+2032). A literal string rather than regex escapes
  # because PCRE rejects \uXXXX inside character classes on some builds; it is
  # interpolated into the classes below instead.
  @apostrophes "'\u2018\u2019\u02bc\u2032"

  @token_pattern Regex.compile!("[\\p{L}\\p{N}#{@apostrophes}]+", "u")
  @apostrophes_regex Regex.compile!("[#{@apostrophes}]", "u")
  @leading_apostrophes Regex.compile!("^[#{@apostrophes}]+", "u")
  @trailing_apostrophes Regex.compile!("[#{@apostrophes}]+$", "u")

  @type options :: map() | keyword()

  @doc """
  The default normalization pipeline, as a map of options.

  Returns a map with the keys `:fold_l_r`, `:strip_diacritics`,
  `:collapse_repeats` and `:strip_prefixes`, all `true`. Use it as the base when
  building custom option sets.
  """
  @spec defaults() :: map()
  def defaults, do: @defaults

  @doc """
  Normalizes `text` and returns a single normalized string.

  Spaces are preserved (runs of whitespace collapse to one space) so the result
  can still be read, but the output is intended for comparison rather than
  display.

  ## Options

  Any of `#{inspect(Map.keys(@defaults))}`, plus a `:normalization` map that is
  merged in first.
  """
  @spec normalize(binary(), options()) :: binary()
  def normalize(text, opts \\ %{})

  def normalize(text, opts) when is_binary(text) do
    opts = effective(opts)

    text
    |> strip_accents(opts)
    |> String.downcase()
    |> collapse_repeats(opts)
    |> fold_l_r(opts)
    |> then(&Regex.replace(@apostrophes_regex, &1, "'"))
    |> then(&Regex.replace(@whitespace, &1, " "))
    |> String.trim()
  end

  @doc """
  Normalizes `text` and splits it into a list of tokens.

  Tokens are runs of letters, digits and apostrophes. Leading and trailing
  apostrophes are trimmed and empty tokens are dropped, so punctuation such as
  `"yego!!"` yields `["yego"]`.
  """
  @spec tokens(binary(), options()) :: [binary()]
  def tokens(text, opts \\ %{}) when is_binary(text) do
    text
    |> tokenize(opts)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Normalizes `text` and splits it into tokens, keeping track of where each token
  came from.

  Returns a list of `{normalized_token, byte_offset, byte_length}` triples. The
  offset and length describe the token in the **original** string, before any
  normalization, which is what lets `KinyarwandaModeration.check/2` report
  positions that can be mapped back onto the text the user actually typed.

  ## Examples

      iex> KinyarwandaModeration.Normalizer.tokenize("Yego, IgiCULU!")
      [{"yego", 0, 4}, {"igicuru", 6, 7}]

  """
  @spec tokenize(binary(), options()) :: [{binary(), non_neg_integer(), non_neg_integer()}]
  def tokenize(text, opts \\ %{}) when is_binary(text) do
    opts = effective(opts)

    @token_pattern
    |> Regex.scan(text, return: :index)
    |> List.flatten()
    |> Enum.map(fn {start, length} -> {start, length, binary_part(text, start, length)} end)
    |> Enum.flat_map(fn {start, _length, raw} ->
      case trim_apostrophes(raw) do
        {"", _lead} -> []
        {body, lead} -> [{normalize(body, opts), start + lead, byte_size(body)}]
      end
    end)
  end

  @doc """
  Returns the lookup candidates for a single already-tokenized `token`.

  The first element is always the normalized token itself. Any further elements
  are noun-class stems, present only when `:strip_prefixes` is enabled and the
  stem is at least #{@min_stem_length} characters long.

  ## Examples

      iex> KinyarwandaModeration.Normalizer.variants("umunyarwanda")
      ["umunyarwanda", "nyarwanda"]

      iex> KinyarwandaModeration.Normalizer.variants("yego")
      ["yego"]

  """
  @spec variants(binary(), options()) :: [binary()]
  def variants(token, opts \\ %{}) when is_binary(token) do
    opts = effective(opts)
    base = normalize(token, opts)
    stems = if opts[:strip_prefixes], do: stems(base), else: []

    [base | stems]
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Returns the noun-class stems of an already normalized `token`.

  Exposed mainly for tests and tooling; most callers want `variants/2`.
  """
  @spec stems(binary()) :: [binary()]
  def stems(token) when is_binary(token) do
    for prefix <- @noun_class_prefixes,
        String.starts_with?(token, prefix),
        stem = String.replace_prefix(token, prefix, ""),
        String.length(stem) >= @min_stem_length,
        do: stem
  end

  @doc """
  Merges user-supplied options over the defaults.

  Accepts either a keyword list or a map, and unwraps a nested `:normalization`
  map (the shape a lexicon file uses) before merging.
  """
  @spec effective(options()) :: map()
  def effective(opts) do
    opts = to_map(opts)
    nested = opts |> Map.get(:normalization, %{}) |> to_map()
    base = Map.delete(opts, :normalization)

    @defaults
    |> Map.merge(nested)
    |> Map.merge(base)
  end

  @doc """
  Resolves `overrides` on top of a base option set, ignoring unknown keys.

  Only the keys that appear in both `overrides` and the known option set are
  applied, so a caller - or a lexicon - can override a single flag without
  having to restate the other three. This is what lets
  `KinyarwandaModeration.check/2` honour `strip_prefixes: false` for one call
  without discarding the normalization the lexicon declared.
  """
  @spec resolve(options(), options()) :: map()
  def resolve(base, overrides) do
    overrides = overrides |> to_map() |> Map.take(Map.keys(@defaults))

    base |> effective() |> Map.merge(overrides)
  end

  defp to_map(opts) when is_list(opts), do: opts |> Map.new() |> normalize_keys()
  defp to_map(opts) when is_map(opts), do: normalize_keys(opts)
  defp to_map(_opts), do: %{}

  defp normalize_keys(opts) do
    Map.new(opts, fn
      {key, value} when is_binary(key) -> {Map.get(@option_names, key, key), value}
      {key, value} -> {key, value}
    end)
  end

  defp strip_accents(text, %{strip_diacritics: true}) do
    text
    |> String.normalize(:nfd)
    |> then(&Regex.replace(@combining_marks, &1, ""))
  end

  defp strip_accents(text, _opts), do: text

  defp collapse_repeats(text, %{collapse_repeats: true}),
    do: Regex.replace(@repeated_letter, text, "\\1")

  defp collapse_repeats(text, _opts), do: text

  defp fold_l_r(text, %{fold_l_r: true}), do: String.replace(text, "l", "r")
  defp fold_l_r(text, _opts), do: text

  # A bare "'" is not a token, but an apostrophe inside a word may be meaningful,
  # so only the edges are trimmed. Returns the trimmed token plus the byte offset
  # of its first character within the original input. Regex rather than
  # String.trim/2 because String.trim/2 only understands ASCII trim sets.
  defp trim_apostrophes(text) do
    stripped = Regex.replace(@leading_apostrophes, text, "")

    {Regex.replace(@trailing_apostrophes, stripped, ""), byte_size(text) - byte_size(stripped)}
  end
end
