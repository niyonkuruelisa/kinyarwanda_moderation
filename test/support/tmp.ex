defmodule KinyarwandaModeration.Tmp do
  @moduledoc """
  Scratch files for tests.

  Tests must never write into the repository root, `test/`, or the OS temp
  directory. Every scratch file belongs in the repo-local `tmp/` directory,
  which is gitignored, so a crashed or interrupted run cannot leave files that
  show up in `git status`. See `AGENTS.md`.
  """

  @dir Path.expand("../tmp", __DIR__)

  @doc """
  Returns the gitignored `tmp/` directory, creating it if needed.
  """
  @spec dir() :: String.t()
  def dir do
    File.mkdir_p!(@dir)
    @dir
  end

  @doc """
  Returns a path inside `tmp/` for a scratch file.

  Names are made unique per test process so that asynchronous test files can
  never collide on the same file.
  """
  @spec path(String.t()) :: String.t()
  def path(name) do
    Path.join(dir(), "#{unique()}_#{name}")
  end

  @doc """
  Writes `content` to a scratch file and returns its path.
  """
  @spec write!(String.t(), iodata()) :: String.t()
  def write!(name, content) do
    path = path(name)
    File.write!(path, content)
    path
  end

  @doc """
  Returns a path inside `tmp/` that is guaranteed not to exist.
  """
  @spec missing(String.t()) :: String.t()
  def missing(name) do
    path = path(name)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
    end

    path
  end

  defp unique do
    :erlang.phash2({node(), self(), System.unique_integer()})
  end
end
