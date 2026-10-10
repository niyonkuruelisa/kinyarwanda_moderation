defmodule KinyarwandaModeration.Result do
  @moduledoc """
  The outcome of `KinyarwandaModeration.check/2`.

  A result is designed to be acted on without raising: the whole point of
  moderation is to decide what to do with content, not to reject it. The
  `:action` field carries the decision (`:allow`, `:flag`, `:review` or
  `:reject`), taken from the most severe match found, so a changeset can react
  quietly - for example by moving a record into a `"pending_review"` state
  instead of returning a validation error to the user.
  """

  alias KinyarwandaModeration.Match

  @enforce_keys [:text, :normalized, :action, :severity, :matches]
  defstruct [
    :text,
    :normalized,
    :action,
    :severity,
    :matches,
    :lexicon_version,
    :redacted
  ]

  @type t :: %__MODULE__{
          text: binary(),
          normalized: binary(),
          action: atom(),
          severity: atom() | nil,
          matches: [Match.t()],
          lexicon_version: binary() | nil,
          redacted: binary()
        }

  @doc """
  Returns `true` when the text matched at least one lexicon entry.
  """
  @spec toxic?(t()) :: boolean()
  def toxic?(%__MODULE__{matches: matches}), do: matches != []

  @doc """
  Returns the number of matches found.
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{matches: matches}), do: length(matches)

  @doc """
  Returns the distinct category ids that matched, in order of first appearance.
  """
  @spec category_ids(t()) :: [binary()]
  def category_ids(%__MODULE__{matches: matches}) do
    matches
    |> Enum.map(& &1.category_id)
    |> Enum.uniq()
  end

  @doc """
  Converts the result into a plain map of primitive values.

  Convenient for logging, for storing a moderation verdict alongside a database
  record, or for handing the verdict to a front-end as JSON.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      toxic: toxic?(result),
      action: result.action,
      severity: result.severity,
      count: count(result),
      categories: category_ids(result),
      matches:
        Enum.map(result.matches, fn match ->
          %{
            term: match.term,
            category: match.category_id,
            severity: match.severity,
            action: match.action,
            token_offset: match.token_offset,
            term_count: match.term_count,
            byte_offset: match.byte_offset,
            byte_length: match.byte_length
          }
        end)
    }
  end
end
