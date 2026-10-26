defmodule ComposerNew.Ref do
  @moduledoc """
  Parses a `mix composer.new` recipe address, `COOKBOOK/CHAPTER/RECIPE`,
  as `--recipe` takes it.

      iex> ComposerNew.Ref.parse("cb_lab/lv/base")
      {:ok,
       %{
         kind: :recipe,
         scope: :qualified,
         cookbook: "cb_lab",
         up: 0,
         segments: ["lv", "base"],
         source: [],
         spec: nil
       }}

  This is a copy of the address grammar of `Composer.Ref` (the archive
  can't depend on composer), and a fixture shared by both projects' tests
  keeps the two in step:

    * the address is split on its first `@`; only the part before it is
      normalized from `-` to `_`
    * the separator gives the kind (`/` a recipe, `:` a step) and the first
      character the scope (a name, a leading separator, a leading `.`); a
      bare name is a search
    * names are lowercase `[a-z0-9_]`; `.` and `..` only begin an address;
      one kind of separator per address; relative steps are reserved
    * only `hex:` takes an `@` source, and one package name; a source is a
      version (`3.5.0` is `== 3.5.0`, a partial `3.5` is `~> 3.0`,
      Igniter's rule, and a requirement such as `~> 3.5` is kept),
      `github:OWNER/REPO[@GITREF]`, `git:URL` or `path:PATH`

  `parse_address/1` is the shared grammar; `parse/1` adds the archive's
  rule: the address is a qualified recipe (no root, relative, search,
  step or `hex:` address). Where a recipe's cookbook comes from is
  `--cookbook`'s business, so a recipe takes no source.

  Parsing never creates atoms.
  """

  @name ~r/\A[a-z0-9_]+\z/
  @hex_package ~r/\A[a-z0-9_]+(\.[a-z0-9_]+)?\z/
  @github_repo ~r/\A[^\/\s@]+\/[^\/\s@]+\z/

  @type source :: keyword(String.t())
  @type t :: %{
          kind: :recipe | :step | nil,
          scope: :qualified | :root | :relative | :search,
          cookbook: String.t() | nil,
          up: non_neg_integer(),
          segments: [String.t()],
          source: source(),
          spec: String.t() | nil
        }

  @example "cb_lab/lv/base"

  @doc """
  Parses a recipe address for `mix composer.new`'s `--recipe`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(string) when is_binary(string) do
    with :ok <- no_source(string),
         {:ok, ref} <- parse_address(string),
         :ok <- archive_rules(string, ref),
         do: {:ok, ref}
  end

  @doc "Parses any address of the shared grammar, without the archive's rules."
  @spec parse_address(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse_address(string) when is_binary(string) do
    {name, spec} = split(string)
    invalid = &{:error, invalid(string, &1)}

    with {:ok, ref} <- classify(String.replace(name, "-", "_"), invalid),
         {:ok, source} <- address_source(ref, spec, string, invalid) do
      {:ok, Map.merge(ref, %{source: source, spec: spec})}
    end
  end

  @doc "The recipe an address names, as `mix composer.recipe.run` takes it."
  @spec recipe(t()) :: String.t()
  def recipe(%{cookbook: cookbook, segments: segments}),
    do: cookbook <> "/" <> Enum.join(segments, "/")

  @doc """
  Parses a bare source, with no package name, as `--composer` takes it:
  `path:../composer`, `github:owner/repo`, `~> 0.3`, ...
  """
  @spec parse_source(String.t()) :: {:ok, source()} | {:error, String.t()}
  def parse_source(spec) when is_binary(spec), do: parse_spec({:source, spec}, spec)

  @doc """
  The `mix composer_new.install` argument for `package` from `spec` (the text
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
  `--install` and `--cookbook` take it.
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

  defp address(kind, scope, cookbook, up, segments),
    do: %{kind: kind, scope: scope, cookbook: cookbook, up: up, segments: segments}

  # Mirrors Composer.Ref's classification.
  defp classify("", invalid), do: invalid.("an address is empty")
  defp classify("." <> _ = name, invalid), do: relative(name, invalid)

  defp classify("/" <> rest = name, invalid) do
    with :ok <- one_separator(name, invalid),
         {:ok, segments} <- segments(rest, "/", invalid),
         do: {:ok, address(:recipe, :root, nil, 0, segments)}
  end

  defp classify(":" <> rest = name, invalid) do
    with :ok <- one_separator(name, invalid),
         {:ok, segments} <- segments(rest, ":", invalid),
         do: {:ok, address(:step, :root, nil, 0, segments)}
  end

  defp classify(name, invalid) do
    with :ok <- one_separator(name, invalid) do
      case :binary.match(name, ["/", ":"]) do
        :nomatch ->
          if Regex.match?(@name, name),
            do: {:ok, address(nil, :search, nil, 0, [name])},
            else: invalid.(name_reason(name))

        {at, 1} ->
          kind = if binary_part(name, at, 1) == "/", do: :recipe, else: :step
          cookbook = binary_part(name, 0, at)
          rest = binary_part(name, at + 1, byte_size(name) - at - 1)
          qualified(cookbook, kind, rest, invalid)
      end
    end
  end

  defp qualified(cookbook, kind, rest, invalid) do
    cond do
      not Regex.match?(@name, cookbook) ->
        invalid.("cookbook names are lowercase [a-z0-9_]")

      cookbook == "hex" and kind == :recipe ->
        invalid.("hex is a step cookbook; a Hex package is written hex:<package>")

      cookbook == "hex" ->
        if Regex.match?(@hex_package, rest),
          do: {:ok, address(:step, :qualified, "hex", 0, [rest])},
          else: invalid.("a hex: address names one package, e.g. hex:oban or hex:org.pkg")

      true ->
        sep = if kind == :recipe, do: "/", else: ":"

        with {:ok, segments} <- segments(rest, sep, invalid),
             do: {:ok, address(kind, :qualified, cookbook, 0, segments)}
    end
  end

  defp relative(name, invalid) do
    case climb(name) do
      {up, {:recipe, path}} ->
        with :ok <- one_separator(name, invalid),
             {:ok, segments} <- segments(path, "/", invalid),
             do: {:ok, address(:recipe, :relative, nil, up, segments)}

      :step ->
        invalid.("relative step references are not supported yet")

      :error ->
        invalid.("a relative address starts with ./ or ../, e.g. ./base or ../ui/buttons")
    end
  end

  defp climb("./" <> rest), do: {0, {:recipe, rest}}
  defp climb(".:" <> _), do: :step
  defp climb(name), do: climb_up(name, 0)

  defp climb_up("../" <> rest, up), do: climb_up(rest, up + 1)
  defp climb_up("..:" <> _, _up), do: :step
  defp climb_up(_rest, 0), do: :error
  defp climb_up(rest, up), do: {up, {:recipe, rest}}

  defp one_separator(name, invalid) do
    if String.contains?(name, "/") and String.contains?(name, ":") do
      invalid.(
        "an address uses one separator, / for a recipe or : for a step; " <>
          "write #{inspect(String.replace(name, ":", "/"))} or " <>
          inspect(String.replace(name, "/", ":"))
      )
    else
      :ok
    end
  end

  defp segments(rest, sep, invalid) do
    segments = String.split(rest, sep)

    cond do
      Enum.any?(segments, &(&1 in [".", ".."])) ->
        invalid.(". and .. may only begin an address, as in ./base or ../buttons")

      Enum.any?(segments, &(&1 == "")) ->
        invalid.("an address has no empty segments (#{sep}#{sep} or a trailing #{sep})")

      bad = Enum.find(segments, &(not Regex.match?(@name, &1))) ->
        invalid.(name_reason(bad))

      true ->
        {:ok, segments}
    end
  end

  defp name_reason(name), do: "#{inspect(name)} is not a name; names are lowercase [a-z0-9_]"

  defp address_source(_ref, nil, _original, _invalid), do: {:ok, []}

  defp address_source(%{cookbook: "hex", segments: [package]}, spec, original, invalid) do
    case String.split(spec, ":", parts: 2) do
      [kind, value] when kind in ~w(github git path) and value != "" ->
        if String.contains?(package, "."),
          do: invalid.("a private-repo package (org.pkg) takes a version, not a #{kind}: source"),
          else: parse_spec(original, spec)

      _ ->
        parse_spec(original, spec)
    end
  end

  defp address_source(%{segments: segments}, spec, _original, invalid) do
    invalid.(
      "only a hex: address takes an @ source; for a Hex package write " <>
        inspect("hex:" <> List.last(segments) <> "@" <> spec)
    )
  end

  # A recipe with an @ source was the old REF form; point at --cookbook.
  defp no_source(string) do
    case split(string) do
      {name, spec} when is_binary(spec) ->
        if String.contains?(name, "/") and not String.starts_with?(name, ["/", "."]) do
          [cookbook | _] = String.split(name, "/")

          why =
            if cookbook == "cb_std",
              do: "cb_std ships with composer; drop the @source",
              else:
                "a recipe takes no @source; give its cookbook's with " <>
                  "--cookbook #{String.replace(cookbook, "-", "_")}@#{spec}"

          {:error, invalid(string, why)}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp archive_rules(original, %{kind: :recipe, scope: :qualified, segments: [_]}),
    do:
      {:error,
       invalid(original, "a recipe address is COOKBOOK/CHAPTER/RECIPE, such as #{@example}")}

  defp archive_rules(_original, %{kind: :recipe, scope: :qualified}), do: :ok

  defp archive_rules(original, %{cookbook: "hex"}),
    do:
      {:error,
       invalid(original, "hex: names a package, not a recipe; write a recipe such as #{@example}")}

  defp archive_rules(original, %{kind: :step}),
    do:
      {:error,
       invalid(original, "that is a step; mix composer.new takes a recipe such as #{@example}")}

  defp archive_rules(original, %{scope: scope}) do
    what =
      case scope do
        :root -> "a cookbook-root address"
        :relative -> "a relative address"
        :search -> "a bare name"
      end

    {:error, invalid(original, "#{what} has no cookbook; name it, as in #{@example}")}
  end

  # Mirrors Composer.Ref's parse_spec/3.
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
