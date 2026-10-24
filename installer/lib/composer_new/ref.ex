defmodule ComposerNew.Ref do
  @moduledoc """
  Parses a `mix composer.new` recipe reference: `COOKBOOK:GROUP/RECIPE`,
  with an optional `@SOURCE` naming where the cookbook comes from.

      iex> ComposerNew.Ref.parse("cb_lab:lv/base@github:elixir-composer/cb_lab@v0.3.0")
      {:ok,
       %{
         cookbook: "cb_lab",
         path: "lv/base",
         source: [github: "elixir-composer/cb_lab", ref: "v0.3.0"],
         spec: "github:elixir-composer/cb_lab@v0.3.0"
       }}

  This is a copy of the name and `@source` rules of `Composer.Ref` (the
  archive can't depend on composer), and a fixture shared by both
  projects' tests keeps the two in step:

    * the reference is split on its first `@`; only the name before it is
      normalized from `-` to `_`
    * names are lowercase `[a-z0-9_]` segments
    * a source is a version (`3.5.0` is `== 3.5.0`, a partial `3.5` is
      `~> 3.0`, Igniter's rule, and a requirement such as `~> 3.5` is kept),
      `github:OWNER/REPO[@GITREF]`, `git:URL` or `path:PATH`

  On top of those, a reference here must name a cookbook (no shortnames),
  can't be `hex:`, and `core:`, which ships with composer, takes no
  source.

  Parsing never creates atoms.
  """

  @segment ~r/\A[a-z0-9_]+\z/
  @github_repo ~r/\A[^\/\s@]+\/[^\/\s@]+\z/

  @type source :: keyword(String.t())
  @type t :: %{
          cookbook: String.t(),
          path: String.t(),
          source: source(),
          spec: String.t() | nil
        }

  @doc """
  Parses a reference. `spec` is the text after the `@` as written, or
  `nil`; `source` is its parsed form (`[]` for none, meaning the latest
  Hex release).
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(string) when is_binary(string) do
    {name, spec} = split(string)

    with {:ok, cookbook, path} <- parse_name(string, name),
         :ok <- archive_rules(string, cookbook, spec),
         {:ok, source} <- parse_spec(string, spec) do
      {:ok, %{cookbook: cookbook, path: path, source: source, spec: spec}}
    end
  end

  @doc """
  Parses a bare source, with no package name, as `--composer` takes it:
  `path:../composer`, `github:owner/repo`, `~> 0.3`, ...
  """
  @spec parse_source(String.t()) :: {:ok, source()} | {:error, String.t()}
  def parse_source(spec) when is_binary(spec), do: parse_spec({:source, spec}, spec)

  @doc """
  The `mix igniter.install` argument for `package` from `spec` (the text
  after `@`, or `nil`), with a `path:` source made absolute against
  `env.cwd` and `env.home`, since the install runs inside the new app.
  """
  @spec install_spec(String.t(), String.t() | nil, %{cwd: Path.t(), home: Path.t()}) ::
          String.t()
  def install_spec(package, nil, _env), do: package
  def install_spec(package, "path:" <> path, env), do: "#{package}@path:#{expand(path, env)}"
  def install_spec(package, spec, _env), do: "#{package}@#{spec}"

  @doc """
  Like `install_spec/3`, for a whole `package[@spec]` string as
  `--install` and `--extra-dep` take it.
  """
  @spec expand_package(String.t(), %{cwd: Path.t(), home: Path.t()}) :: String.t()
  def expand_package(string, env) do
    {name, spec} = split(string)
    install_spec(name, spec, env)
  end

  @doc "Expands `path` against `env.cwd`, with a leading `~` as `env.home`."
  @spec expand(Path.t(), %{cwd: Path.t(), home: Path.t()}) :: Path.t()
  def expand("~", env), do: env.home
  def expand("~/" <> rest, env), do: Path.join(env.home, rest)
  def expand(path, env), do: Path.expand(path, env.cwd)

  defp split(string) do
    case String.split(String.trim(string), "@", parts: 2) do
      [name] -> {name, nil}
      [name, spec] -> {name, spec}
    end
  end

  defp parse_name(original, name) do
    case String.split(String.replace(name, "-", "_"), ":") do
      [_path] ->
        {:error,
         invalid(
           original,
           "refs must name a cookbook (cookbook:group/recipe); shortnames aren't supported"
         )}

      [cookbook, path] ->
        cond do
          not Regex.match?(@segment, cookbook) ->
            {:error, invalid(original, "cookbook names are lowercase [a-z0-9_]")}

          not valid_path?(path) ->
            {:error,
             invalid(
               original,
               "a path is one or more `/`-separated lowercase [a-z0-9_] segments"
             )}

          true ->
            {:ok, cookbook, path}
        end

      _ ->
        {:error, invalid(original, "a reference has at most one `:`")}
    end
  end

  defp archive_rules(original, "hex", _spec),
    do: {:error, invalid(original, "hex: names a package, not a cookbook")}

  defp archive_rules(original, "core", spec) when spec != nil,
    do: {:error, invalid(original, "core ships with composer; drop the @source")}

  defp archive_rules(_original, _cookbook, _spec), do: :ok

  defp valid_path?(path) do
    path != "" and path |> String.split("/") |> Enum.all?(&Regex.match?(@segment, &1))
  end

  # Mirrors Composer.Ref's parse_spec/3.
  defp parse_spec(_original, nil), do: {:ok, []}

  defp parse_spec(original, spec) do
    case String.split(spec, ":", parts: 2) do
      [""] ->
        {:error,
         invalid(
           original,
           "nothing follows the @; write a version, github:, git: or path: source"
         )}

      [kind, ""] when kind in ["github", "git", "path"] ->
        {:error, invalid(original, "the #{kind}: source is empty")}

      [kind, _value] when kind in ["github", "git", "path"] ->
        source_spec(original, kind, spec)

      [_version] ->
        version_spec(original, spec)

      [kind, _value] ->
        {:error,
         invalid(original, "unknown source #{kind}:; the sources are github:, git: and path:")}
    end
  end

  defp source_spec(original, "github", "github:" <> value) do
    {repo, ref} =
      case String.split(value, "@", parts: 2) do
        [repo] -> {repo, nil}
        [repo, ref] -> {repo, ref}
      end

    cond do
      not Regex.match?(@github_repo, repo) ->
        {:error, invalid(original, "a github: source is owner/repo, got #{inspect(repo)}")}

      ref == "" ->
        {:error, invalid(original, "nothing follows the @ of the github: source; write a ref")}

      ref == nil ->
        {:ok, [github: repo]}

      true ->
        {:ok, [github: repo, ref: ref]}
    end
  end

  defp source_spec(_original, "git", "git:" <> url), do: {:ok, [git: url]}
  defp source_spec(_original, "path", "path:" <> path), do: {:ok, [path: path]}

  defp version_spec(original, spec) do
    with :error <- Version.parse(spec),
         :error <- general_requirement(spec),
         :error <- Version.parse_requirement(spec) do
      {:error,
       invalid(original, "#{inspect(spec)} is not a version, a version requirement or a source")}
    else
      {:ok, %Version{} = version} -> {:ok, [version: "== #{version}"]}
      {:ok, requirement} when is_binary(requirement) -> {:ok, [version: requirement]}
      {:ok, %Version.Requirement{}} -> {:ok, [version: spec]}
    end
  end

  # A copy of Igniter.Util.Version.version_string_to_general_requirement/1.
  defp general_requirement(version) do
    padded =
      case String.split(version, ".", trim: true) do
        [_major, _minor] -> version <> ".0"
        [_major] -> version <> ".0.0"
        _ -> version
      end

    case Version.parse(padded) do
      {:ok, %Version{major: major, minor: minor, patch: patch, pre: pre}} when pre != [] ->
        {:ok, "~> #{major}.#{minor}.#{patch}-#{Enum.join(pre, ".")}"}

      {:ok, %Version{major: 0, minor: minor}} ->
        {:ok, "~> 0.#{minor}"}

      {:ok, %Version{major: major}} ->
        {:ok, "~> #{major}.0"}

      :error ->
        :error
    end
  end

  defp invalid({:source, spec}, why), do: "Invalid source #{inspect(spec)}: #{why}."
  defp invalid(original, why), do: "Invalid reference #{inspect(original)}: #{why}."
end
