defmodule KinyarwandaModeration.Match do
  @moduledoc """
  A single hit returned by `KinyarwandaModeration.check/2`.

  Positions are reported in **tokens**, not characters or bytes, because
  Kinyarwanda normalization can change a string's length (diacritics are
  stripped and repeated letters are collapsed). `:byte_offset` and
  `:byte_length` refer to the original, un-normalized input so you can map a hit
  back onto the string the user actually typed.
  """

  @enforce_keys [
    :term,
    :tokens,
    :category_id,
    :action,
    :severity,
    :token_offset,
    :term_count,
    :byte_offset,
    :byte_length
  ]
  defstruct [
    :term,
    :tokens,
    :category_id,
    :category_label,
    :action,
    :severity,
    :token_offset,
    :term_count,
    :byte_offset,
    :byte_length
  ]

  @type t :: %__MODULE__{
          term: binary(),
          tokens: [binary()],
          category_id: binary(),
          category_label: binary() | nil,
          action: atom(),
          severity: atom(),
          token_offset: non_neg_integer(),
          term_count: pos_integer(),
          byte_offset: non_neg_integer(),
          byte_length: non_neg_integer()
        }

  @doc """
  The exclusive end byte offset of the match within the original input.
  """
  @spec byte_end(t()) :: non_neg_integer()
  def byte_end(%__MODULE__{byte_offset: offset, byte_length: length}), do: offset + length
end
