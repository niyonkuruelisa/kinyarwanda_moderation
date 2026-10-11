defmodule KinyarwandaModeration.Normalizer do
  @moduledoc """
  Text normalization tuned for Kinyarwanda.

  Generic profanity filters fail on Kinyarwanda for reasons that are specific to
  how the language is written online. This module handles the four that matter
  most:

    * **l / r folding** - Kinyarwanda has no native *l* in most positions, so
      writers frequently swap *l* and *r* for each other. The fold is one way:
      only *l* becomes *r*, so `igiculu` and `igicuru` normalize to the same
      token. It runs before the squashes because turning an *l* into an *r* can
      leave two *r*s side by side.

    * **Diacritic folding** - The standard orthography is unaccented, but users
      type `é`, `á`, `è` and friends anyway. Text is decomposed to NFD and the
      combining marks are dropped.

    * **Repeat collapsing** - Runs of three or more identical letters are
      collapsed to one, which defeats padding such as `amaaani`. Double
      squashing subsumes this for letters, so on the default pipeline it is only
      observable when `squash_doubles: false`; it stays a separate switch for
      callers who want triple-run padding gone without merging `amaani`.

    * **Double squashing** - Any doubled letter is collapsed to one, so
      `igiituba`, `igituuba` and `igitubba` all reach a listed `igituba`. The
      lexicon is squashed the same way, which is what makes the comparison
      symmetric. It costs recall when an evader pads a listed word and costs
      precision only when an innocent doubled spelling squashes onto a *listed*
      term, so it is on by default. It also merges the long-vowel spellings
      `amaani` and `kuubona` onto `amani` and `kubona`; that is safe because the
      lexicon side is merged identically, so a listed `amaani` still matches.

    * **Noun-class prefix stripping** - Kinyarwanda nouns inflect heavily by
      prefix (`umu-`, `aba-`, `iki-`, `ibi-`, ...). Matching a root term also
      checks the stems left after removing a known prefix, so inflected forms
      still hit.

    * **Augment dropping** - A noun's initial vowel usually disappears when it
      follows a locative or a verb, leaving the class prefix glued onto the
      stem (`ku` + `igituba` becomes `kugituba`). Matching a term also checks
      the form with its initial vowel removed, so the glued spelling still hits.

    * **Phrase gluing** - Multi-word entries are also checked with their spaces
      removed (`kanywe nzobya` / `kanywenzobya`), because writers routinely run
      the words of a phrase together.

  Everything happens at the **token boundaries** the matcher works on, so these
  rules cannot see inside a word. A term listed as `cumita` still will not match
  `uyumucumita`, because the token itself is `uyumucumita`.

  Every rule is individually switchable, either globally through the options
  accepted here or per-lexicon through the `"normalization"` object in
  `data/rw_lexicon.json`.

  ## Examples

      iex> KinyarwandaModeration.Normalizer.normalize("  IgiCULU ")
      "igicuru"

      iex> KinyarwandaModeration.Normalizer.tokens("Amaaani, yego!")
      ["amani", "yego"]

      iex> KinyarwandaModeration.Normalizer.variants("abadeputa")
      ["abadeputa", "deputa", "badeputa"]

  """

  @defaults %{
    fold_l_r: true,
    strip_diacritics: true,
    squash_doubles: true,
    collapse_repeats: true,
    strip_prefixes: true,
    augment_drop: true,
    glued_phrases: true
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

  # Kinyarwanda nouns normally carry an initial-vowel augment (`i-gituba`,
  # `u-mwana`). In connected speech the augment drops after a locative or a verb
  # and the class prefix is left glued straight onto the stem:
  #
  #     ku  + igituba -> kugituba
  #     ibi + igituba -> ibigituba
  #     ndi + igituba -> ndigigituba
  #
  # The bare vowel is matched rather than the full class prefix because the
  # prefix that survives is unrelated to the one the lexicon entry carries
  # (`ibi-` and `ku-` both leave `gituba`). See `drop_augment/1`.
  @augments ~w(a e i o u)

  @combining_marks ~r/[\p{Mn}\p{Mc}]/u
  @whitespace ~r/\s+/u
  @repeated_letter ~r/(.)\1{2,}/u

  # Any run of two or more of the same letter. Letters only, so whitespace and
  # punctuation are untouched.
  #
  # Doubling is legitimate in a handful of Kinyarwanda words, notably the
  # consonant `nny` in `innyo` and `ubunnyano`. There is no guard for them on
  # purpose: `nny` is just `n` followed by the `ny` digraph, so shrinking it is
  # the same edit that collapses doubled-`n` padding, and the two cannot be
  # told apart. No distinction is needed either, because the lexicon side is
  # squashed identically, so a term listed as `innyo` is matched by `innyo`,
  # `inyo` and `innyoo` alike. Guarding `nny` would only lose recall: padding
  # `ny` as `nny` is a plausible evasion (see the `kanywenzobya` regression).
  @doubled_letter ~r/(\p{L})\1+/u

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
  `:squash_doubles`, `:collapse_repeats`, `:strip_prefixes`, `:augment_drop`
  and `:glued_phrases`, all `true`. Use it as the base when building custom
  option sets.
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

    # The order of the three letter rules is load-bearing.
    #
    # fold_l_r comes first because it is the only rule that rewrites one letter
    # into another, and it rewrites l to r. Running it after the squashes lets it
    # create a fresh doubled letter that nothing collapses afterwards (`lrl`
    # becomes `rrr`, then `r`), which makes the pipeline non-idempotent and makes
    # variants/2 disagree with normalize/2 about the same token.
    #
    # collapse_repeats must stay ahead of squash_doubles. A three-letter run
    # such as `amaaani` already satisfies the squash, so running the squash
    # first would collapse it even with `collapse_repeats: false` and make that
    # switch unobservable.
    text
    |> strip_accents(opts)
    |> String.downcase()
    |> fold_l_r(opts)
    |> collapse_repeats(opts)
    |> squash_doubles(opts)
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
  are alternates produced by the inflection rules:

    * noun-class stems, when `:strip_prefixes` is enabled and the stem is at
      least #{@min_stem_length} characters long
    * the augment-dropped form, when `:augment_drop` is enabled and the drop
      leaves at least #{@min_stem_length} characters

  `:glued_phrases` is not applied here - it needs the whole entry, so it is
  handled by `KinyarwandaModeration.Lexicon` when entries are compiled.

  ## Examples

      iex> KinyarwandaModeration.Normalizer.variants("umunyarwanda")
      ["umunyarwanda", "nyarwanda", "munyarwanda"]

      iex> KinyarwandaModeration.Normalizer.variants("kugituba")
      ["kugituba", "gituba"]

      iex> KinyarwandaModeration.Normalizer.variants("yego")
      ["yego"]

  """
  @spec variants(binary(), options()) :: [binary()]
  def variants(token, opts \\ %{}) when is_binary(token) do
    opts = effective(opts)
    base = normalize(token, opts)

    [base | stems(base, opts) ++ dropped(base, opts)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Returns the noun-class stems of an already normalized `token`.

  Exposed mainly for tests and tooling; most callers want `variants/2`.
  """
  @spec stems(binary(), options()) :: [binary()]
  def stems(token, opts \\ %{}) when is_binary(token) do
    if effective(opts)[:strip_prefixes], do: prefix_stems(token), else: []
  end

  @doc """
  Returns the form of an already normalized `token` with its initial-vowel
  augment removed, or `[]` when the token has no augment or the result would be
  shorter than #{@min_stem_length} characters.

  Exposed mainly for tests and tooling; most callers want `variants/2`.
  """
  @spec augment_dropped(binary(), options()) :: [binary()]
  def augment_dropped(token, opts \\ %{}) do
    if effective(opts)[:augment_drop], do: drop_augment(token), else: []
  end

  defp prefix_stems(token) do
    for prefix <- @noun_class_prefixes,
        String.starts_with?(token, prefix),
        stem = String.replace_prefix(token, prefix, ""),
        String.length(stem) >= @min_stem_length,
        do: stem
  end

  # Only the initial vowel is removed. What remains is the class prefix plus the
  # stem (`igituba` -> `gituba`), which is exactly the shape an augment drop
  # leaves behind, whichever locative or verb caused the drop. Gating on the
  # resulting length is what keeps short entries (`imboro` -> `mboro` is fine,
  # but `aba` -> `ba` is not) from matching far too much.
  defp drop_augment(<<first::utf8, rest::binary>>) do
    if List.to_string([first]) in @augments and String.length(rest) >= @min_stem_length do
      [rest]
    else
      []
    end
  end

  defp drop_augment(_token), do: []

  defp dropped(token, opts) do
    if opts[:augment_drop], do: drop_augment(token), else: []
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
  having to restate the others. This is what lets
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

  defp squash_doubles(text, %{squash_doubles: true}),
    do: Regex.replace(@doubled_letter, text, "\\1")

  defp squash_doubles(text, _opts), do: text

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
