defmodule ComposerNew.Dep do
  @moduledoc """
  A package for `mix composer_new.install`, `NAME[@SOURCE]`, and the
  dependency it becomes in the app's `mix.exs`.

  SOURCE is parsed by `ComposerNew.Ref.parse_source/1`, so it is written
  as in `mix composer.new --cookbook`:

      iex> ComposerNew.Dep.parse("composer@~> 0.3")
      {:ok, %{name: "composer", opts: [], source: [version: "~> 0.3"]}}

      iex> ComposerNew.Dep.to_igniter(%{name: "composer", opts: [], source: [version: "~> 0.3"]})
      {:composer, "~> 0.3"}

  `mix igniter.install` takes the same `NAME@SOURCE` strings, but only
  versions: a requirement such as `~> 0.3` is an error there, and a
  `git:` URL is split at its `@`. Handing Igniter the dependency itself
  keeps both as written.

  NAME may name a Hex organization (`org/name`) or repository
  (`repo.name`), as in `mix igniter.install`.
  """

  alias ComposerNew.Ref

  @package ~r/\A[a-z][a-z0-9_]*\z/

  @type t :: %{name: String.t(), opts: keyword(String.t()), source: Ref.source()}

  @doc "Parses `NAME[@SOURCE]`. Parsing never creates atoms."
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(string) when is_binary(string) do
    {name, spec} =
      case String.split(String.trim(string), "@", parts: 2) do
        [name] -> {name, nil}
        [name, spec] -> {name, spec}
      end

    with {:ok, name, opts} <- parse_name(string, name),
         {:ok, source} <- parse_source(string, spec) do
      {:ok, %{name: name, opts: opts, source: source}}
    end
  end

  @doc """
  The dependency tuple Igniter adds to `mix.exs`, or `:latest` for a
  package without a source, which Igniter resolves to the latest Hex
  release.
  """
  @spec to_igniter(t()) :: :latest | tuple()
  def to_igniter(%{source: []}), do: :latest

  def to_igniter(%{name: name, opts: opts, source: [version: requirement]}) do
    if opts == [],
      do: {String.to_atom(name), requirement},
      else: {String.to_atom(name), requirement, opts}
  end

  # As igniter.install: a git, github or path dep overrides any the
  # package's own deps declare.
  def to_igniter(%{name: name, opts: opts, source: source}),
    do: {String.to_atom(name), source ++ [override: true] ++ opts}

  defp parse_name(original, string) do
    {opts, name} =
      case String.split(string, "/", parts: 2) do
        [org, rest] -> {[organization: org], rest}
        [rest] -> {[], rest}
      end

    {opts, name} =
      case String.split(name, ".", parts: 2) do
        [repo, rest] -> {Keyword.put(opts, :repo, repo), rest}
        [rest] -> {opts, rest}
      end

    if Regex.match?(@package, name),
      do: {:ok, name, opts},
      else:
        {:error,
         "Invalid package #{inspect(original)}: package names are lowercase [a-z0-9_], " <>
           "starting with a letter."}
  end

  defp parse_source(_original, nil), do: {:ok, []}

  defp parse_source(original, spec) do
    case Ref.parse_source(spec) do
      {:ok, source} -> {:ok, source}
      {:error, message} -> {:error, "Invalid package #{inspect(original)}: #{message}"}
    end
  end
end
