defmodule Composer.Ref do
  @moduledoc """
  A reference to a step or recipe: `"cookbook:path"`.

      iex> Composer.Ref.parse("composer_lab:ash/postgres")
      {:ok, %Composer.Ref{cookbook: "composer_lab", path: "ash/postgres"}}

      iex> Composer.Ref.parse("ash/postgres")
      {:ok, %Composer.Ref{cookbook: nil, path: "ash/postgres"}}

  A path is one or more `/`-separated segments of `[a-z0-9_]`. Input is
  normalized from `-` to `_`, so `daisy-ui` and `daisy_ui` are the same
  name. The `hex:` cookbook also accepts a private-repo package such as
  `hex:oban.oban_pro`.

  ## Sources

  A `hex:` reference may name where the package comes from, after an `@`,
  as `mix igniter.install` does:

      iex> Composer.Ref.parse("hex:ash@3.5")
      {:ok, %Composer.Ref{cookbook: "hex", path: "ash", source: [version: "~> 3.0"]}}

      iex> Composer.Ref.parse("hex:my-lib@path:../my-lib")
      {:ok, %Composer.Ref{cookbook: "hex", path: "my_lib", source: [path: "../my-lib"]}}

    * `@<version>` - `@3.5.0` is `"== 3.5.0"`, a partial version such as
      `@3.5` is `"~> 3.0"` (Igniter's rule), and a requirement with an
      operator (`@~>3.5`) is kept as written
    * `@github:owner/repo`, or `@github:owner/repo@ref`
    * `@git:<url>`
    * `@path:<path>`

  The reference is split on its first `@`, so the spec may contain `:`, `@`
  and `-`; only the package name is normalized. A source is the same
  keyword list as the `version:`/`github:`/`git:`/`path:` options of a
  recipe entry (see `Composer.Recipe`). Any other reference with an `@` is
  invalid.

  Parsing never creates atoms.
  """

  @enforce_keys [:path]
  defstruct cookbook: nil, path: nil, source: []

  @type t :: %__MODULE__{cookbook: String.t() | nil, path: String.t(), source: keyword()}

  @segment ~r/\A[a-z0-9_]+\z/
  @hex_package ~r/\A[a-z0-9_]+(\.[a-z0-9_]+)?\z/
  @github_repo ~r/\A[^\/\s@]+\/[^\/\s@]+\z/

  @doc "Parses a reference string."
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:invalid_ref, String.t(), String.t()}}
  def parse(string) when is_binary(string) do
    {name, spec} =
      case String.split(String.trim(string), "@", parts: 2) do
        [name] -> {name, nil}
        [name, spec] -> {name, spec}
      end

    case String.split(String.replace(name, "-", "_"), ":") do
      [path] -> build(string, nil, path, spec)
      [cookbook, path] -> build(string, cookbook, path, spec)
      _ -> {:error, {:invalid_ref, string, "a reference has at most one `:`"}}
    end
  end

  def parse(other), do: {:error, {:invalid_ref, inspect(other), "a reference must be a string"}}

  @doc "Like `parse/1`, raising `ArgumentError` on an invalid reference."
  @spec parse!(String.t()) :: t()
  def parse!(string) do
    case parse(string) do
      {:ok, ref} -> ref
      {:error, reason} -> raise ArgumentError, Composer.Error.message(reason)
    end
  end

  @doc """
  Formats a reference as `cookbook:path`, or `path` when unqualified, with
  its source in `@` form.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{cookbook: nil, path: path}), do: path

  def to_string(%__MODULE__{cookbook: cookbook, path: path, source: source}),
    do: cookbook <> ":" <> path <> format_source(source)

  @doc "Joins a cookbook name and a path into a qualified reference string."
  @spec id(String.t(), String.t()) :: String.t()
  def id(cookbook, path), do: cookbook <> ":" <> path

  @doc "True when `path` contains a `/`, i.e. it is grouped."
  @spec grouped?(t()) :: boolean()
  def grouped?(%__MODULE__{path: path}), do: String.contains?(path, "/")

  @doc "True when `package` names a package in a private repo (`org.pkg`)."
  @spec repo_package?(String.t()) :: boolean()
  def repo_package?(package), do: String.contains?(package, ".")

  defp build(original, cookbook, path, spec) do
    cond do
      cookbook != nil and not Regex.match?(@segment, cookbook) ->
        {:error, {:invalid_ref, original, "cookbook names are lowercase [a-z0-9_]"}}

      cookbook == "hex" and not Regex.match?(@hex_package, path) ->
        {:error,
         {:invalid_ref, original,
          "a hex: reference names one package, e.g. hex:oban or hex:org.pkg"}}

      cookbook != "hex" and not valid_path?(path) ->
        {:error,
         {:invalid_ref, original,
          "a path is one or more `/`-separated lowercase [a-z0-9_] segments"}}

      spec != nil and cookbook != "hex" ->
        {:error,
         {:invalid_ref, original,
          "only a hex: reference takes an @ source; for a Hex package write " <>
            inspect("hex:" <> path <> "@" <> spec)}}

      spec == nil ->
        {:ok, %__MODULE__{cookbook: cookbook, path: path}}

      true ->
        with {:ok, source} <- parse_spec(original, path, spec) do
          {:ok, %__MODULE__{cookbook: cookbook, path: path, source: source}}
        end
    end
  end

  defp valid_path?(path) do
    path != "" and path |> String.split("/") |> Enum.all?(&Regex.match?(@segment, &1))
  end

  # The spec after `@`, kept verbatim. Mirrors
  # Igniter.Project.Deps.determine_dep_type_and_version!/2.
  defp parse_spec(original, package, spec) do
    invalid = &{:error, {:invalid_ref, original, &1}}

    case String.split(spec, ":", parts: 2) do
      [""] ->
        invalid.("nothing follows the @; write a version, github:, git: or path: source")

      [kind, ""] when kind in ["github", "git", "path"] ->
        invalid.("the #{kind}: source is empty")

      [kind, _value] when kind in ["github", "git", "path"] ->
        if repo_package?(package),
          do: invalid.("a private-repo package (org.pkg) takes a version, not a #{kind}: source"),
          else: source_spec(invalid, kind, spec)

      [_version] ->
        version_spec(invalid, spec)

      [kind, _value] ->
        invalid.("unknown source #{kind}:; the sources are github:, git: and path:")
    end
  end

  defp source_spec(invalid, "github", "github:" <> value) do
    {repo, ref} =
      case String.split(value, "@", parts: 2) do
        [repo] -> {repo, nil}
        [repo, ref] -> {repo, ref}
      end

    cond do
      not Regex.match?(@github_repo, repo) ->
        invalid.("a github: source is owner/repo, got #{inspect(repo)}")

      ref == "" ->
        invalid.("nothing follows the @ of the github: source; write a ref")

      ref == nil ->
        {:ok, [github: repo]}

      true ->
        {:ok, [github: repo, ref: ref]}
    end
  end

  defp source_spec(_invalid, "git", "git:" <> url), do: {:ok, [git: url]}
  defp source_spec(_invalid, "path", "path:" <> path), do: {:ok, [path: path]}

  defp version_spec(invalid, spec) do
    with :error <- Version.parse(spec),
         {:error, _} <- Igniter.Util.Version.version_string_to_general_requirement(spec),
         :error <- Version.parse_requirement(spec) do
      invalid.("#{inspect(spec)} is not a version, a version requirement or a source")
    else
      {:ok, %Version{} = version} -> {:ok, [version: "== #{version}"]}
      {:ok, requirement} when is_binary(requirement) -> {:ok, [version: requirement]}
      {:ok, %Version.Requirement{}} -> {:ok, [version: spec]}
    end
  end

  defp format_source([]), do: ""
  defp format_source(version: requirement), do: "@" <> requirement
  defp format_source(github: repo), do: "@github:" <> repo
  defp format_source(github: repo, ref: ref), do: "@github:" <> repo <> "@" <> ref
  defp format_source(git: url), do: "@git:" <> url
  defp format_source(path: path), do: "@path:" <> path
end
