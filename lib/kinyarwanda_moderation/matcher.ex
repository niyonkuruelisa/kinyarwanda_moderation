defmodule KinyarwandaModeration.Matcher do
  @moduledoc """
  A compiled lexicon, ready to scan token sequences.

  The matcher is an [Aho-Corasick](https://en.wikipedia.org/wiki/Aho%E2%80%93Corasick_algorithm)
  automaton built over **token sequences** rather than characters. Two reasons:

    1. It finds every match in a single left-to-right pass, so cost is linear in
       the length of the text no matter how large the lexicon grows.
    2. Working on tokens means a two-word phrase can never match across a word
       boundary by accident, which character-level filters get wrong constantly.

  The automaton is written in plain Elixir with no dependencies, and both sides
  of the comparison are expanded with `KinyarwandaModeration.Normalizer.variants/2`
  when prefix stripping is enabled, so a lexicon root and an inflected form of it
  still meet in the middle.

  ## Where the compiled matcher lives

  `install/1` puts the automaton in `:persistent_term`, which makes every read
  lock-free - no GenServer round trip and no ETS lookup on the hot path. Writing
  to `:persistent_term` is comparatively expensive because it forces a global
  scan of the process heaps, so it should happen at boot and on explicit
  `KinyarwandaModeration.reload/1`, not per request.
  """

  alias KinyarwandaModeration.{Lexicon, Normalizer}

  @key {__MODULE__, :current}

  # Guards against a pathological entry turning into hundreds of automaton paths
  # when every one of its tokens expands to several prefix-stripped variants.
  @max_paths 128

  defstruct [
    :goto,
    :fail,
    :output,
    :entries,
    :normalization,
    :lexicon_version,
    :locale,
    :node_count
  ]

  @type hit :: %{
          entry_index: non_neg_integer(),
          start_token: integer(),
          end_token: non_neg_integer(),
          entry: Lexicon.entry()
        }

  @type t :: %__MODULE__{
          goto: tuple(),
          fail: tuple(),
          output: tuple(),
          entries: tuple(),
          normalization: map(),
          lexicon_version: binary(),
          locale: binary(),
          node_count: pos_integer()
        }

  @doc """
  Compiles a `KinyarwandaModeration.Lexicon` into a matcher.
  """
  @spec compile(Lexicon.t()) :: t()
  def compile(%Lexicon{} = lexicon) do
    entries = List.to_tuple(lexicon.entries)

    paths =
      lexicon.entries
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, index} ->
        entry.tokens
        |> expansion(lexicon.normalization)
        |> Enum.map(&{&1, index})
      end)

    {goto, output, count} =
      Enum.reduce(paths, {%{}, %{}, 1}, fn {tokens, index}, acc -> insert(acc, tokens, index) end)

    {fail, output} = links(goto, output)

    %__MODULE__{
      goto: as_tuple(goto, count, %{}),
      fail: as_tuple(fail, count, 0),
      output: as_tuple(output, count, []),
      entries: entries,
      normalization: lexicon.normalization,
      lexicon_version: lexicon.version,
      locale: lexicon.locale,
      node_count: count
    }
  end

  @doc """
  Scans a list of already-normalized `tokens` and returns every hit.

  Hits are deduplicated and returned in the order they were discovered. Feed the
  tokens to `KinyarwandaModeration.check/2` instead if you want `Match` structs
  with byte offsets.
  """
  @spec scan(t(), [binary()]) :: [hit()]
  def scan(%__MODULE__{} = matcher, tokens) when is_list(tokens) do
    tokens
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new([0]), []}, fn {token, index}, {active, acc} ->
      variants = Normalizer.variants(token, matcher.normalization)

      {next, acc} =
        Enum.reduce(active, {MapSet.new(), acc}, fn node, {next, acc} ->
          Enum.reduce(variants, {next, acc}, fn variant, {next, acc} ->
            case step(matcher, node, variant) do
              nil -> {next, acc}
              child -> {MapSet.put(next, child), emit(matcher, child, index, acc)}
            end
          end)
        end)

      # the root is always active again so a match may start at the next token
      {MapSet.put(next, 0), acc}
    end)
    |> elem(1)
    |> Enum.uniq_by(&{&1.entry_index, &1.start_token})
    |> Enum.reverse()
  end

  @doc """
  Stores `matcher` as the process-wide current matcher.

  See the module documentation for why this uses `:persistent_term`.
  """
  @spec install(t()) :: :ok
  def install(%__MODULE__{} = matcher), do: :persistent_term.put(@key, matcher)

  @doc """
  Returns the installed matcher, or `nil` when none has been installed yet.
  """
  @spec current() :: t() | nil
  def current, do: :persistent_term.get(@key, nil)

  @doc """
  Removes the installed matcher.
  """
  @spec clear() :: :ok
  def clear do
    _ = :persistent_term.erase(@key)
    :ok
  end

  @doc """
  The number of states in the automaton. Useful when tuning the lexicon.
  """
  @spec node_count(t()) :: pos_integer()
  def node_count(%__MODULE__{node_count: count}), do: count

  # -- trie construction ----------------------------------------------------

  defp insert({goto, output, count}, tokens, index) do
    Enum.reduce(tokens, {0, goto, output, count}, fn token, {node, goto, output, count} ->
      children = Map.get(goto, node, %{})

      case Map.fetch(children, token) do
        {:ok, child} ->
          {child, goto, output, count}

        :error ->
          child = count
          goto = Map.put(goto, node, Map.put(children, token, child))
          {child, goto, output, count + 1}
      end
    end)
    |> then(fn {node, goto, output, count} ->
      {goto, Map.update(output, node, [index], &[index | &1]), count}
    end)
  end

  defp links(goto, output) do
    children = Map.get(goto, 0, %{})

    fail = Map.new(children, fn {_token, child} -> {child, 0} end)
    queue = children |> Map.values() |> :queue.from_list()

    bfs(queue, goto, fail, output)
  end

  defp bfs(queue, goto, fail, output) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        {fail, output}

      {{:value, node}, queue} ->
        {queue, fail, output} =
          Enum.reduce(Map.get(goto, node, %{}), {queue, fail, output}, fn {token, child}, acc ->
            {queue, fail, output} = acc
            target = follow(goto, fail, Map.get(fail, node, 0), token)

            fail = Map.put(fail, child, target)

            output =
              Map.update(
                output,
                child,
                Map.get(output, target, []),
                &(&1 ++ Map.get(output, target, []))
              )

            {:queue.in(child, queue), fail, output}
          end)

        bfs(queue, goto, fail, output)
    end
  end

  defp follow(goto, fail, node, token) do
    case Map.fetch(Map.get(goto, node, %{}), token) do
      {:ok, child} -> child
      :error when node == 0 -> 0
      :error -> follow(goto, fail, Map.get(fail, node, 0), token)
    end
  end

  defp step(%__MODULE__{} = matcher, node, token) do
    case Map.fetch(elem(matcher.goto, node), token) do
      {:ok, child} -> child
      :error when node == 0 -> nil
      :error -> step(matcher, elem(matcher.fail, node), token)
    end
  end

  defp emit(matcher, node, index, acc) do
    Enum.reduce(elem(matcher.output, node), acc, fn entry_index, acc ->
      entry = elem(matcher.entries, entry_index)
      start = index - entry.term_count + 1

      [
        %{entry_index: entry_index, start_token: start, end_token: index, entry: entry}
        | acc
      ]
    end)
  end

  defp as_tuple(map, count, default) do
    0..(count - 1)
    |> Enum.map(&Map.get(map, &1, default))
    |> List.to_tuple()
  end

  # -- entry expansion ------------------------------------------------------

  @doc false
  # Every way an entry can be written once each of its tokens is replaced by its
  # prefix-stripped variants. Capped by @max_paths so a long phrase cannot blow
  # the automaton up.
  def expansion(tokens, normalization) do
    tokens
    |> Enum.map(&Normalizer.variants(&1, normalization))
    |> combinations()
    |> Enum.uniq()
    |> Enum.take(@max_paths)
  end

  defp combinations([]), do: [[]]

  defp combinations([variants | rest]) do
    tails = combinations(rest)

    for variant <- variants, tail <- tails, do: [variant | tail]
  end
end
