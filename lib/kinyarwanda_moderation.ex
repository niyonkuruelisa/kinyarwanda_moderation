defmodule KinyarwandaModeration do
  @moduledoc """
  Content moderation for Kinyarwanda text, built for Elixir and Phoenix.

  Generic profanity filters are written for English and quietly fail on
  Kinyarwanda. This library is built the other way around: the normalization
  pipeline, the lexicon format and the matcher are all shaped by how Kinyarwanda
  is actually written online.

      iex> KinyarwandaModeration.toxic?("this is fine")
      false

  ## The short version

      KinyarwandaModeration.toxic?("some text")
      #=> true | false

      KinyarwandaModeration.check("some text")
      #=> %KinyarwandaModeration.Result{}

  `toxic?/2` answers a yes/no question. `check/2` returns the full verdict:
  every match, the category it belongs to, and a suggested `:action`
  (`:allow`, `:flag`, `:review` or `:reject`). Nothing ever raises on toxic
  input - moderation is a decision about content, not a validation failure.

  ## What makes this different from a word list

  Kinyarwanda is agglutinative and inconsistently spelled online, so an exact
  substring search misses most real-world cases. Seven normalizations and
  derivations run on both the lexicon **and** the incoming text, which is what
  keeps them symmetric:

    * **l / r folding** - every *l* becomes *r*, so `igiculu` and `igicuru`
      normalize to the same token. A writer spelling an *r* as an *l* cannot
      dodge a listed term, whichever spelling the term itself uses.
    * **Diacritic folding** - `é`, `á`, `è` are reduced to their base letters.
    * **Double squashing** - `igiituba`, `igituuba` and `igitubba` all reach a
      listed `igituba`, because a doubled letter is squashed to one on both
      sides. Padding a word with a repeated letter no longer evades a match.
    * **Repeat collapsing** - `amaaani` becomes `amani`, defeating padding.
    * **Noun-class prefix stripping** - the stem of `abadeputa` also matches a
      lexicon entry for `deputa`.
    * **Augment dropping** - a locative or verb that swallows the initial vowel
      of a noun is put back: `kugituba` reaches a listed `igituba`, because one
      side loses the augment (`igituba` -> `gituba`) and the other loses the
      prefix (`kugituba` -> `gituba`).
    * **Phrase gluing** - every multi-word phrase gains a space-stripped alias,
      so a writer who runs it together still matches: `kanywenzobya` reaches a
      listed `kanywe nzobya`.

  Matching itself is [Aho-Corasick](https://en.wikipedia.org/wiki/Aho%E2%80%93Corasick_algorithm)
  over **token sequences**, so a phrase never matches across a word boundary and
  scanning stays linear in the length of the text as the lexicon grows. The
  implementation is dependency-free pure Elixir. See
  `KinyarwandaModeration.Normalizer` and `KinyarwandaModeration.Matcher`.

  ## Where a listed word matches

  There is no `contains`, `startswith` or `endswith` option, and none is needed,
  because every listed word already behaves like all three at once. A lexicon
  entry is matched wherever it starts inside the token stream, and both sides are
  expanded before the comparison, so a prefix on the text behaves like a prefix
  on the entry, and the entry behaves like a stem:

  | The writer typed | The lexicon lists | Matches? | Why |
  | --- | --- | --- | --- |
  | `igituba` | `igituba` | yes | exact token |
  | `igituba` | `tuba` | yes | entry stems to `tuba` |
  | `kugituba` | `igituba` | yes | augment drop meets prefix stripping |
  | `kanywenzobya` | `kanywe nzobya` | yes | phrase gluing |
  | `uyumucumita` | `cumita` | **no** | the word is buried mid-token |
  | `nywe nzobya` | `kanywe nzobya` | no | the leading token is missing |

  The one shape the engine cannot see is a word glued into the **middle** of a
  longer token (`cumita` inside `uyumucumita`), because the automaton walks
  tokens, not characters. Listing the full inflected spelling, or adding the
  augment-dropped stem as its own entry, is the supported way to catch those.

  ## The lexicon

  Lexicons are plain JSON (see `data/lexicon.schema.json`), which means the
  word list is a data asset you version, review and translate without touching
  code:

      {:ok, raw} =
        "data/rw_lexicon.json"
        |> File.read()
        |> then(fn {:ok, body} -> {:ok, KinyarwandaModeration.JSON.decode!(body)} end)

      KinyarwandaModeration.compile(raw)

  The bundled `data/rw_lexicon.json` ships with **placeholder** entries only.
  It is a working example of the format, not a hate-speech list. See the
  `"notice"` field inside it.

  ## Installation

      def deps do
        [
          {:kinyarwanda_moderation,
           git: "https://github.com/niyonkuruelisa/kinyarwanda_moderation.git", tag: "v0.1.0"}
        ]
      end

  ## Configuration

  The library installs the bundled lexicon at boot. To point it somewhere else -
  your own vetted lexicon, or a directory of localized ones - configure it:

      config :kinyarwanda_moderation, lexicon: "/etc/moderation/rw_lexicon.json"

  A missing or invalid configured lexicon is logged and the bundled default is
  used instead, so a bad config never takes the host application down. Call
  `reload/1` after replacing a lexicon file to pick up the change.
  """

  use Application

  require Logger

  alias KinyarwandaModeration.{Lexicon, Match, Matcher, Normalizer, Result}

  @doc false
  def start(_type, _args) do
    children = [
      %{
        id: __MODULE__,
        start: {__MODULE__, :install_lexicon, []}
      }
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: KinyarwandaModeration.Supervisor
    )
  end

  @doc false
  def install_lexicon do
    case Application.get_env(:kinyarwanda_moderation, :lexicon, :default) do
      :default ->
        _ = load(:default)

      source ->
        case load(source) do
          {:ok, _matcher} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "kinyarwanda_moderation: could not load lexicon from #{inspect(source)} " <>
                "(#{reason}); falling back to the bundled default"
            )

            _ = load(:default)
        end
    end

    :ignore
  end

  @doc """
  Returns `true` when `text` matches at least one lexicon entry.

  ## Options

  See `check/2`. The same options are accepted, so a caller can, for example,
  disable prefix stripping for a short display name where precision matters more
  than recall.

  ## Examples

      iex> KinyarwandaModeration.toxic?("this is fine")
      false

  """
  @spec toxic?(binary(), keyword() | map()) :: boolean()
  def toxic?(text, opts \\ []) when is_binary(text), do: text |> check(opts) |> Result.toxic?()

  @doc """
  Evaluates `text` and returns a `KinyarwandaModeration.Result`.

  Never raises: empty or nil-ish input simply produces a benign result. The
  `:action` on the result is the most severe action among all matches, using
  `KinyarwandaModeration.Lexicon.actions/0` as the ordering.

  ## Options

    * `:matcher` - a `KinyarwandaModeration.Matcher` to use instead of the
      installed one. Useful for tests and for scanning with several lexicons.
    * `:lexicon` - a `KinyarwandaModeration.Lexicon` to compile on the fly.
    * `:redact?` - when `true`, also populates `Result.redacted` with the input
      where every matched span is replaced by `:replacement`.
    * `:replacement` - the string used for redaction. Defaults to `"[...]"`.
    * any `KinyarwandaModeration.Normalizer` option, which overrides the
      normalization declared by the lexicon for this call only.

  ## Examples

      iex> result = KinyarwandaModeration.check("this is fine")
      iex> result.action
      :allow

  """
  @spec check(binary() | nil, keyword() | map()) :: Result.t()
  def check(text, opts \\ [])

  def check(nil, _opts), do: empty_result("")

  def check(text, opts) when is_binary(text) do
    case matcher(opts) do
      nil ->
        empty_result(text)

      %Matcher{} = matcher ->
        normalization = normalization(matcher, opts)
        {tokens, spans} = tokens_with_spans(text, normalization)
        hits = Matcher.scan(matcher, tokens)
        matches = to_matches(hits, spans)

        result = %Result{
          text: text,
          normalized: Normalizer.normalize(text, normalization),
          action: worst_action(matches),
          severity: worst_severity(matches),
          matches: matches,
          lexicon_version: matcher.lexicon_version
        }

        if redact?(opts), do: %{result | redacted: redact(text, matches, opts)}, else: result
    end
  end

  @doc """
  Compiles and installs a lexicon, replacing the current one.

  `source` is anything `KinyarwandaModeration.Lexicon.load/2` accepts: a path to
  a `.json` file, a directory, or `:default` for the bundled lexicon.

  Returns `{:ok, matcher}` or `{:error, reason}` - invalid data is reported, not
  raised, because a lexicon is configuration that can legitimately be stale or
  half-written on disk.

  ## Examples

      iex> match?({:ok, %KinyarwandaModeration.Matcher{}}, KinyarwandaModeration.reload(:default))
      true

  """
  @spec reload(binary() | :default, keyword()) :: {:ok, Matcher.t()} | {:error, term()}
  def reload(source \\ :default, opts \\ []), do: load(source, opts)

  @doc """
  Compiles a raw, already-decoded lexicon and installs it as the current one.

  Accepts the same two shapes as `KinyarwandaModeration.Lexicon.load/2`: a
  structured lexicon map or a flat list of terms. Handy in tests and in
  applications that generate a lexicon at runtime rather than reading it from
  disk.
  """
  @spec compile(map() | [binary()], keyword()) :: {:ok, Matcher.t()} | {:error, term()}
  def compile(raw, opts \\ []) do
    matcher = raw |> Lexicon.build(nil, opts) |> Matcher.compile()
    :ok = Matcher.install(matcher)
    {:ok, matcher}
  rescue
    error in [ArgumentError] -> {:error, Exception.message(error)}
  end

  @doc """
  Returns the currently installed matcher, or `nil` when none is installed.
  """
  @spec matcher() :: Matcher.t() | nil
  def matcher, do: Matcher.current()

  @doc """
  Returns the version string of the installed lexicon, or `nil`.

  Store this alongside a moderation verdict so a decision can be audited against
  the exact word list that produced it.

  ## Examples

      iex> KinyarwandaModeration.lexicon_version()
      "0.1.0"

  """
  @spec lexicon_version() :: binary() | nil
  def lexicon_version do
    case matcher() do
      %Matcher{lexicon_version: version} -> version
      nil -> nil
    end
  end

  @doc """
  Returns the normalization settings the installed lexicon declares.

  Useful for debugging why something did or did not match.
  """
  @spec normalization() :: map()
  def normalization do
    case matcher() do
      %Matcher{normalization: normalization} -> normalization
      nil -> Normalizer.defaults()
    end
  end

  @doc """
  Normalizes `text` with the installed lexicon's pipeline.

  Exposed so callers can log or display what the matcher actually saw.
  """
  @spec normalize(binary(), keyword() | map()) :: binary()
  def normalize(text, opts \\ %{}) when is_binary(text), do: Normalizer.normalize(text, opts)

  @doc """
  Returns the paths this library can load a lexicon from, most specific first.

  Useful in error output and in `mix` tasks that validate the data files.
  """
  @spec lexicon_sources() :: [binary()]
  def lexicon_sources do
    [
      Application.get_env(:kinyarwanda_moderation, :lexicon),
      Lexicon.default_path(),
      Lexicon.default_path(from: :release)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  # -- internals ------------------------------------------------------------

  defp load(source, opts \\ []) do
    matcher = source |> Lexicon.load(opts) |> Matcher.compile()
    :ok = Matcher.install(matcher)
    {:ok, matcher}
  rescue
    error in [ArgumentError, File.Error] ->
      {:error, Exception.message(error)}
  end

  defp matcher(opts) do
    opts = normalize_opts(opts)

    cond do
      match?(%Matcher{}, opts[:matcher]) -> opts[:matcher]
      match?(%Lexicon{}, opts[:lexicon]) -> Matcher.compile(opts[:lexicon])
      true -> Matcher.current()
    end
  end

  # The lexicon declares the normalization its entries were written against, but
  # a caller may override individual flags for one call. Only the flags actually
  # passed may win, which is what Normalizer.resolve/2 guarantees.
  defp normalization(%Matcher{normalization: normalization}, opts),
    do: Normalizer.resolve(normalization, opts)

  defp tokens_with_spans(text, normalization) do
    spans = Normalizer.tokenize(text, normalization)

    {Enum.map(spans, fn {token, _offset, _length} -> token end), List.to_tuple(spans)}
  end

  defp to_matches(hits, spans) do
    Enum.map(hits, fn hit ->
      entry = hit.entry
      span = elem(spans, hit.start_token)
      length = span_length(spans, hit.start_token, entry.term_count)

      %Match{
        term: entry.term,
        tokens: entry.tokens,
        category_id: entry.category_id,
        category_label: entry.category_label,
        action: entry.action,
        severity: entry.severity,
        token_offset: hit.start_token,
        term_count: entry.term_count,
        byte_offset: span_offset(span),
        byte_length: length
      }
    end)
  end

  defp span_offset({_token, start, _length}), do: start

  defp span_length(spans, start_token, term_count) do
    first = elem(spans, start_token)
    {_token, last_offset, last_length} = elem(spans, start_token + term_count - 1)

    # from the first token's byte offset through the end of the last one, so any
    # punctuation between them stays inside the reported span
    last_offset + last_length - span_offset(first)
  end

  defp worst_action([]), do: :allow

  defp worst_action(matches) do
    matches
    |> Enum.map(& &1.action)
    |> Enum.max_by(&Enum.find_index(Lexicon.actions(), fn action -> action == &1 end))
  end

  defp worst_severity([]), do: nil

  defp worst_severity(matches) do
    matches
    |> Enum.map(& &1.severity)
    |> Enum.max_by(&Enum.find_index(Lexicon.severities(), fn severity -> severity == &1 end))
  end

  defp redact?(opts) do
    opts = to_map(opts)
    opts[:redact?] == true or opts[:redact] == true
  end

  defp redact(text, [], _opts), do: text

  defp redact(text, matches, opts) do
    replacement = Keyword.get(normalize_opts(opts), :replacement, "[...]")

    matches
    |> Enum.map(&{&1.byte_offset, &1.byte_length})
    |> Enum.sort_by(&elem(&1, 0))
    |> merge_spans()
    |> Enum.reduce({[], 0}, fn {offset, length}, {acc, cursor} ->
      # acc is reverse-ordered, so the replacement is pushed before the untouched
      # text that precedes it
      {[replacement, binary_part(text, cursor, offset - cursor) | acc], offset + length}
    end)
    |> then(fn {acc, cursor} ->
      [binary_part(text, cursor, byte_size(text) - cursor) | acc]
    end)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  # overlapping matches collapse into one span so the replacement is not applied
  # twice to the same bytes
  defp merge_spans(spans) do
    spans
    |> Enum.reduce([], fn {offset, length}, acc ->
      case acc do
        [{previous_offset, previous_length} | rest]
        when offset <= previous_offset + previous_length ->
          [{previous_offset, max(previous_length, offset + length - previous_offset)} | rest]

        _ ->
          [{offset, length} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_opts(_opts), do: []

  defp to_map(opts) when is_list(opts), do: Map.new(opts)
  defp to_map(opts) when is_map(opts), do: opts
  defp to_map(_opts), do: %{}

  defp empty_result(text) do
    %Result{
      text: text,
      normalized: Normalizer.normalize(text, normalization()),
      action: :allow,
      severity: nil,
      matches: [],
      lexicon_version: lexicon_version()
    }
  end
end
