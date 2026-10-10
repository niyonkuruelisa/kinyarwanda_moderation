defmodule KinyarwandaModeration.JSON do
  @moduledoc """
  Minimal JSON decoding shim.

  The library ships with **no runtime dependencies**. On OTP 27 and later it uses
  the built-in `:json` module. If you are on an older OTP release, adding `Jason`
  to your own dependencies is enough and it will be picked up automatically.
  """

  @doc """
  Decodes a JSON binary into Elixir terms, raising on failure.

  ## Examples

      iex> KinyarwandaModeration.JSON.decode!("[\\"a\\"]")
      ["a"]

  """
  @spec decode!(binary()) :: term()
  def decode!(binary) when is_binary(binary) do
    case backend() do
      :erlang_json -> :json.decode(binary)
      # apply/3 rather than a direct call: Jason is an optional dependency, so a
      # direct call would not compile with --warnings-as-errors when it is absent
      :jason -> apply(Jason, :decode!, [binary])
      :none -> raise_missing_backend!()
    end
  end

  @doc """
  Returns which JSON backend is in use: `:erlang_json`, `:jason`, or `:none`.
  """
  @spec backend() :: :erlang_json | :jason | :none
  def backend do
    cond do
      Code.ensure_loaded?(:json) -> :erlang_json
      Code.ensure_loaded?(Jason) -> :jason
      true -> :none
    end
  end

  defp raise_missing_backend! do
    raise """
    no JSON decoder available.

    KinyarwandaModeration has no runtime dependencies and relies on one of:

      * the `:json` module, built into Erlang/OTP 27 and later, or
      * `Jason`, if you add it to your own dependencies.

    Add `{:jason, "~> 1.4"}` to your deps, or upgrade to OTP 27+.
    """
  end
end
