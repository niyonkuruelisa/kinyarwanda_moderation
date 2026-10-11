defmodule KinyarwandaModeration.Lexicon do
  @moduledoc """
  Loads and validates a JSON lexicon.

  A lexicon maps terms and phrases to the category they belong to, and every
  category carries a `severity` and a suggested `action`. The on-disk shape is
  documented by `data/lexicon.schema.json`.

  ## Loading

  `load/1` accepts:

    * a path to a `.json` file,
    * a path to a directory, in which case the bundled `rw_lexicon.json` is
      looked up inside it,
    * `:default` (or no argument), which resolves to the lexicon shipped in this
      package's `data` directory.

  Both on-disk shapes are accepted: the structured object exemplified by
  `data/rw_lexicon.json`, and a flat JSON array of terms such as
  `data/rw_hate_speech.json`. A flat array becomes a single
  `"flat_terms"` category, since it carries no per-term metadata.

  Terms are normalized with the pipeline the lexicon itself declares, so the
  lexicon author - not the caller - decides how aggressively the data is folded.
  `KinyarwandaModeration` reuses those same settings when it normalizes incoming
  text, which is what keeps the two sides symmetric.
  """

  alias KinyarwandaModeration.Normalizer

  @default_file "rw_lexicon.json"
  @data_dir "data"

  # Captured at compile time: the project root of the source checkout. This is
  # what makes `data/` resolvable when the library is consumed as a Mix
  # dependency, because deps keep their source tree on disk.
  @source_root Path.expand("../..", __DIR__)

  # Defaults applied to the flat `["term", ...]` form, which has nowhere to
  # declare them. Deliberately the middle of the road: flag rather than reject,
  # because a plain word list carries no context.
  @flat_category_id "flat_terms"
  @flat_category_label "Flat term list"
  @flat_severity :medium
  @flat_action :flag
  @flat_locale "rw"

  @actions %{"allow" => :allow, "flag" => :flag, "review" => :review, "reject" => :reject}
  @severities %{"low" => :low, "medium" => :medium, "high" => :high}

  # Explicit orderings rather than Map.values/1: small maps are stored in key
  # order, not insertion order, so deriving these from the maps above would
  # silently produce the wrong ranking.
  @action_order [:allow, :flag, :review, :reject]
  @severity_order [:low, :medium, :high]

  @enforce_keys [:version, :locale, :normalization, :entries, :categories]
  defstruct [:version, :locale, :updated, :notice, :normalization, :entries, :categories, :path]

  @typedoc "A category as declared in the lexicon file."
  @type category :: %{
          id: binary(),
          label: binary() | nil,
          action: atom(),
          severity: atom(),
          description: binary() | nil,
          term_count: non_neg_integer()
        }

  @typedoc "One entry that text is matched against: a term, or a phrase of tokens."
  @type entry :: %{
          term: binary(),
          tokens: [binary()],
          term_count: pos_integer(),
          category_id: binary(),
          category_label: binary() | nil,
          action: atom(),
          severity: atom()
        }

  @type t :: %__MODULE__{
          version: binary(),
          locale: binary(),
          updated: binary() | nil,
          notice: binary() | nil,
          normalization: map(),
          categories: [category()],
          entries: [entry()],
          path: binary() | nil
        }

  @doc """
  Resolves the path of the lexicon shipped with this package.

  The lexicon lives in `data/` at the root of this project, next to `lib/`, not
  under `priv/`. Mix only copies `priv/` into the build output, so a root `data/`
  directory is never mirrored into `_build` on its own; resolution therefore
  happens at runtime against a short list of candidates:

    1. the `data/` inside the built application directory, when build tooling
       copied it there,
    2. the `data/` of the source tree this module was compiled from, which is
       what resolves for a checkout and for a dependency under `deps/`,
    3. the `priv/data` of a release, for lexicons packaged before the move.

  Ordering flips under `from: :release`, where the release's own copy is the
  authoritative one. The first candidate that exists on disk wins, and the first
  candidate is returned as-is when none of them do, so the error a caller sees
  names the most likely location.
  """
  @spec default_path(keyword() | map()) :: binary()
  def default_path(opts \\ []) do
    candidates(opts)
    |> Enum.find(&File.regular?/1)
    |> Kernel.||(hd(candidates(opts)))
  end

  @doc """
  Returns the candidate paths `default_path/1` searches, in order.

  Useful for diagnostics, and for tests that must not depend on which of the
  candidates happens to exist on the machine running them.
  """
  @spec default_path_candidates(keyword() | map()) :: [binary()]
  def default_path_candidates(opts \\ []), do: candidates(opts)

  defp candidates(opts) do
    case get_opt(opts, :from, :code) do
      :release ->
        [priv_path(), app_data_path(), source_data_path()]

      _ ->
        [app_data_path(), source_data_path(), priv_path()]
    end
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp app_data_path do
    Path.join([Application.app_dir(:kinyarwanda_moderation), @data_dir, @default_file])
  end

  defp source_data_path do
    Path.join([@source_root, @data_dir, @default_file])
  end

  # Returns a path even when no `priv` directory exists on disk, so this
  # candidate is only ever selected if `default_path/1` finds a real file there.
  # Guarded anyway: `:code.priv_dir/1` raises when the application is not loaded.
  defp priv_path do
    try do
      Path.join([:code.priv_dir(:kinyarwanda_moderation), @data_dir, @default_file])
    rescue
      ArgumentError -> nil
    end
  end

  @doc """
  Loads and validates a lexicon, raising `ArgumentError` if anything is wrong.

  Errors name the offending path and category so a contributor editing the JSON
  can fix it without reading this module.

  Two on-disk shapes are accepted:

    * the structured object documented by `data/lexicon.schema.json` and
      exemplified by `data/rw_lexicon.json`, and
    * a flat JSON array of terms, such as
      `["term_one", "term_two"]` (see `data/rw_hate_speech.json`). A flat
      list is treated as a single `#{inspect(@flat_category_id)}` category; use
      the structured form when you need severities and actions per category.
  """
  @spec load(binary() | :default, keyword() | map()) :: t()
  def load(source \\ :default, opts \\ [])

  def load(:default, opts), do: load(default_path(opts), opts)

  def load(source, opts) when is_binary(source) do
    path = resolve(source)

    path
    |> File.read!()
    |> decode!(path)
    |> build(path, opts)
  end

  @doc """
  Validates an already-decoded lexicon map without touching the filesystem.

  `path` is only used to make error messages readable. Handy for tests and for CI
  checks that guard the data files.
  """
  @spec build(map() | [binary()], binary() | nil, keyword() | map()) :: t()
  def build(raw, path \\ nil, opts \\ [])

  def build(raw, path, opts) when is_list(raw) do
    build(
      %{
        "version" => "0.0.0",
        "locale" => @flat_locale,
        "notice" =>
          "A flat term list carries no version, locale, severity or action metadata, " <>
            "so it was loaded as a single #{inspect(@flat_category_id)} category with " <>
            "severity #{inspect(@flat_severity)} and action #{inspect(@flat_action)}.",
        "categories" => [
          %{
            "id" => @flat_category_id,
            "label" => @flat_category_label,
            "severity" => Atom.to_string(@flat_severity),
            "action" => Atom.to_string(@flat_action),
            "terms" => raw
          }
        ]
      },
      path,
      opts
    )
  end

  def build(raw, path, opts) when is_map(raw) do
    opts = Map.new(opts)
    # validate the required scalars first so errors name the missing key rather
    # than whatever the category walk happens to trip over
    version = fetch_string!(raw, "version", path)
    locale = fetch_string!(raw, "locale", path)
    declared = raw |> Map.get("normalization", %{}) |> Normalizer.effective()
    normalization = Normalizer.effective(Map.merge(opts, %{normalization: declared}))

    categories =
      raw
      |> fetch_list!("categories", path)
      |> Enum.with_index()
      |> Enum.map(&build_category(&1, path))

    entries = Enum.flat_map(categories, &category_entries(&1, path, normalization))

    if entries == [] do
      raise ArgumentError, "#{describe(path)} defines no terms or phrases"
    end

    %__MODULE__{
      version: version,
      locale: locale,
      updated: Map.get(raw, "updated"),
      notice: Map.get(raw, "notice"),
      normalization: normalization,
      categories: Enum.map(categories, &Map.drop(&1, [:terms, :phrases])),
      entries: entries,
      path: path
    }
  end

  def build(raw, path, _opts) do
    raise ArgumentError,
          "#{describe(path)} must decode to a JSON object or an array of terms, got: #{inspect(raw)}"
  end

  @doc """
  Returns the number of entries (terms plus phrases) in `lexicon`.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{entries: entries}), do: length(entries)

  @doc """
  Returns the actions this library understands, ordered from least to most
  severe: `#{inspect(@action_order)}`.
  """
  @spec actions() :: [atom()]
  def actions, do: @action_order

  @doc """
  Returns the severities this library understands, ordered from least to most
  severe: `#{inspect(@severity_order)}`.
  """
  @spec severities() :: [atom()]
  def severities, do: @severity_order

  defp build_category({category, index}, path) when is_map(category) do
    id = fetch_string!(category, "id", path, index)

    terms = list_of(Map.get(category, "terms"), "terms", id, path)
    phrases = list_of(Map.get(category, "phrases"), "phrases", id, path)

    if terms == [] and phrases == [] do
      raise ArgumentError,
            "category #{inspect(id)} in #{describe(path)} defines no terms or phrases"
    end

    %{
      id: id,
      label: Map.get(category, "label"),
      action: parse_enum!(Map.get(category, "action", "review"), @actions, "action", path, id),
      severity:
        parse_enum!(Map.get(category, "severity", "medium"), @severities, "severity", path, id),
      description: Map.get(category, "description"),
      term_count: length(terms) + length(phrases),
      terms: terms,
      phrases: phrases
    }
  end

  defp build_category({other, index}, path) do
    raise ArgumentError,
          "category ##{index} in #{describe(path)} must be an object, got: #{inspect(other)}"
  end

  defp category_entries(category, path, normalization) do
    (category.terms ++ category.phrases)
    |> Enum.flat_map(fn term ->
      tokens = Normalizer.tokens(term, normalization)

      if tokens == [] do
        raise ArgumentError,
              "entry #{inspect(term)} in category #{inspect(category.id)} of #{describe(path)} " <>
                "normalizes to nothing; check for stray punctuation"
      end

      context = %{
        category_id: category.id,
        category_label: category.label,
        action: category.action,
        severity: category.severity
      }

      [entry(term, tokens, context) | glued_entries(term, tokens, normalization, context)]
    end)
  end

  defp entry(term, tokens, context) do
    Map.merge(context, %{term: term, tokens: tokens, term_count: length(tokens)})
  end

  # Writers routinely run the words of a phrase together, and the matcher cannot
  # see inside a token once it is one, so a multi-word entry also gets a
  # space-stripped alias. Emitted as a separate entry with its own `term` - the
  # writer-facing spelling - while `tokens` holds the normalized single token the
  # automaton stores, so the reported match still names something real and the
  # token offsets stay right.
  defp glued_entries(_term, [_single], _normalization, _context), do: []

  defp glued_entries(term, _tokens, normalization, context) do
    if Map.get(normalization, :glued_phrases) do
      glued = String.replace(term, ~r/\s+/u, "")
      normalized = Normalizer.normalize(glued, normalization)

      if Normalizer.tokens(glued, normalization) == [normalized] do
        [entry(glued, [normalized], context)]
      else
        # Gluing is not idempotent for this entry (normalizing it yields more
        # than one token), so the alias would not be the single token we just
        # built and the offsets would be wrong.
        []
      end
    else
      []
    end
  end

  defp list_of(nil, _field, _id, _path), do: []

  defp list_of(list, _field, _id, _path) when is_list(list) do
    Enum.map(list, fn
      value when is_binary(value) -> value
      other -> raise ArgumentError, "lexicon entries must be strings, got: #{inspect(other)}"
    end)
  end

  defp list_of(other, field, id, path) do
    raise ArgumentError,
          "#{field} on category #{inspect(id)} in #{describe(path)} must be an array, got: #{inspect(other)}"
  end

  defp parse_enum!(value, allowed, field, path, id) do
    case Map.fetch(allowed, to_string(value)) do
      {:ok, atom} ->
        atom

      :error ->
        raise ArgumentError,
              "#{field} #{inspect(value)} on category #{inspect(id)} in #{describe(path)} " <>
                "is not one of #{inspect(Map.keys(allowed))}"
    end
  end

  defp fetch_string!(map, key, path, index \\ nil) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" ->
        value

      other ->
        location = if index, do: "category ##{index} in ", else: ""

        raise ArgumentError,
              "#{location}#{describe(path)} is missing a non-empty #{inspect(key)} (got #{inspect(other)})"
    end
  end

  defp fetch_list!(map, key, path) do
    case Map.get(map, key) do
      list when is_list(list) and list != [] ->
        list

      other ->
        raise ArgumentError,
              "#{describe(path)} must define a non-empty #{inspect(key)} array (got #{inspect(other)})"
    end
  end

  defp resolve(path) do
    cond do
      File.regular?(path) -> path
      File.dir?(path) -> Path.join(path, @default_file)
      true -> raise ArgumentError, "no lexicon found at #{path}"
    end
  end

  defp decode!(body, path) do
    KinyarwandaModeration.JSON.decode!(body)
  rescue
    # :json and Jason both signal malformed input with an ErlangError
    error in [ErlangError] ->
      raise ArgumentError, "lexicon #{path} is not valid JSON: #{Exception.message(error)}"
  end

  defp get_opt(opts, key, default) do
    cond do
      is_list(opts) -> Keyword.get(opts, key, default)
      is_map(opts) -> Map.get(opts, key, default)
      true -> default
    end
  end

  defp describe(nil), do: "lexicon"
  defp describe(path), do: "lexicon #{path}"
end
