defmodule Composer.Ref do
  @moduledoc """
  An address of a recipe or a step.

  The separator gives the **kind**, `/` for a recipe and `:` for a step, and
  the first character gives the **scope**:

  | Scope        | Recipe                  | Step                         |
  |--------------|-------------------------|------------------------------|
  | `:qualified` | `cb_std/ash/ui/buttons` | `cb_std:cluster:libcluster`  |
  | `:root`      | `/ash/ui/buttons`       | `:cluster:libcluster`        |
  | `:relative`  | `./base`, `../buttons`  | `.:dns` (reserved, rejected) |
  | `:search`    | `buttons`               | `libcluster`                 |

      iex> Composer.Ref.parse("cb_lab/ash/postgres")
      {:ok, %Composer.Ref{kind: :recipe, scope: :qualified, cookbook: "cb_lab", segments: ["ash", "postgres"]}}

      iex> Composer.Ref.parse("../buttons")
      {:ok, %Composer.Ref{kind: :recipe, scope: :relative, up: 1, segments: ["buttons"]}}

      iex> Composer.Ref.parse(":setup:credo")
      {:ok, %Composer.Ref{kind: :step, scope: :root, segments: ["setup", "credo"]}}

  A name is lowercase `[a-z0-9_]`; input is normalized from `-` to `_`, so
  `daisy-ui` and `daisy_ui` are the same name. A search is a single bare
  name, with no kind; only the command line accepts one (see
  `Composer.Resolver`).

  `.` and `..` appear only as a leading prefix (`./x`, `../x`, `../../x`),
  and an address uses one kind of separator. Relative step references
  (`.:dns`) are reserved and rejected.

  ## `hex:`

  `hex` is a virtual step cookbook: `hex:` takes exactly one name, which
  may name a private-repo package (`hex:oban.oban_pro`), and is the only
  address that takes a source, after an `@`, as `mix igniter.install`
  does:

      iex> Composer.Ref.parse("hex:ash@3.5")
      {:ok, %Composer.Ref{kind: :step, scope: :qualified, cookbook: "hex", segments: ["ash"], source: [version: "~> 3.0"]}}

      iex> Composer.Ref.parse("hex:my-lib@path:../my-lib")
      {:ok, %Composer.Ref{kind: :step, scope: :qualified, cookbook: "hex", segments: ["my_lib"], source: [path: "../my-lib"]}}

    * `@<version>` - `@3.5.0` is `"== 3.5.0"`, a partial version such as
      `@3.5` is `"~> 3.0"` (Igniter's rule), and a requirement with an
      operator (`@~>3.5`) is kept as written
    * `@github:owner/repo`, or `@github:owner/repo@ref`
    * `@git:<url>`
    * `@path:<path>`

  The address is split on its first `@`, so the spec may contain `:`, `@`,
  `/` and `-`; only the part before it is normalized. A source is the same
  keyword list as the `version:`/`github:`/`git:`/`path:` options of a
  recipe entry (see `Composer.Recipe`).

  ## Canonical ids

  `id/3` builds the canonical qualified address from a kind, a cookbook and
  segments (`cb_std:setup:credo`, `cb_std/ash/ui/buttons`). Canonical ids
  are what the completion index, manifests, `--json` output, diagnostics
  and `requires:` matching use. Internally a recipe id is its `/`-joined
  chapter path and key (`"ash/ui/buttons"`) and a step id its `/`-joined
  path under `steps/` (`"cluster/libcluster"`); `id/3` takes either form.

  ## Listing stems

  Listing tasks and completion also take a stem, an address cut after a
  separator: `cb_std/`, `cb_std:`, `cb_std/ash/`, `/`, `:`. See
  `parse_stem/1`.

  Parsing never creates atoms.
  """

  defstruct kind: nil, scope: nil, cookbook: nil, up: 0, segments: [], source: []

  @type kind :: :recipe | :step
  @type scope :: :qualified | :root | :relative | :search

  @type t :: %__MODULE__{
          kind: kind() | nil,
          scope: scope(),
          cookbook: String.t() | nil,
          up: non_neg_integer(),
          segments: [String.t()],
          source: keyword()
        }

  @name ~r/\A[a-z0-9_]+\z/
  @hex_package ~r/\A[a-z0-9_]+(\.[a-z0-9_]+)?\z/
  @github_repo ~r/\A[^\/\s@]+\/[^\/\s@]+\z/

  @doc "Parses an address."
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:invalid_ref, String.t(), String.t()}}
  def parse(string) when is_binary(string) do
    {name, spec} = split(string)
    invalid = &{:error, {:invalid_ref, string, &1}}

    with {:ok, ref} <- classify(String.replace(name, "-", "_"), invalid) do
      attach_source(ref, spec, invalid)
    end
  end

  def parse(other), do: {:error, {:invalid_ref, inspect(other), "an address must be a string"}}

  @doc "Like `parse/1`, raising `ArgumentError` on an invalid address."
  @spec parse!(String.t()) :: t()
  def parse!(string) do
    case parse(string) do
      {:ok, ref} -> ref
      {:error, reason} -> raise ArgumentError, Composer.Error.message(reason)
    end
  end

  @doc """
  Parses a listing stem: an address cut just after a separator, such as
  `cb_std/`, `cb_std:`, `cb_std/ash/`, `cb_std:cluster:`, `/`, `:` or
  `/ash/`. `cookbook` is `nil` for a root stem.

      iex> Composer.Ref.parse_stem("cb_std/ash/")
      {:ok, %{kind: :recipe, cookbook: "cb_std", segments: ["ash"]}}

      iex> Composer.Ref.parse_stem(":")
      {:ok, %{kind: :step, cookbook: nil, segments: []}}
  """
  @spec parse_stem(String.t()) ::
          {:ok, %{kind: kind(), cookbook: String.t() | nil, segments: [String.t()]}}
          | {:error, {:invalid_ref, String.t(), String.t()}}
  def parse_stem(string) when is_binary(string) do
    trimmed = string |> String.trim() |> String.replace("-", "_")

    with sep when sep in ["/", ":"] <- String.last(trimmed),
         kind = kind_of(sep),
         {:ok, ref} <- classify(trimmed <> "x", fn _ -> :error end),
         true <- ref.kind == kind and ref.scope in [:qualified, :root] do
      {:ok, %{kind: kind, cookbook: ref.cookbook, segments: Enum.drop(ref.segments, -1)}}
    else
      _ -> {:error, {:invalid_ref, string, "a stem is an address ending in / or :"}}
    end
  end

  @doc """
  Writes an address in canonical form: `./x`, `../../x`, `/a/b`, `:a:b`,
  `cb/a/b`, `cb:a:b`, `hex:pkg@spec`, or a bare search name.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{scope: :search, segments: [name]}), do: name

  def to_string(%__MODULE__{scope: :relative, up: up, segments: segments}) do
    prefix = if up == 0, do: "./", else: String.duplicate("../", up)
    prefix <> Enum.join(segments, "/")
  end

  def to_string(%__MODULE__{scope: :root, kind: kind, segments: segments}) do
    sep = separator(kind)
    sep <> Enum.join(segments, sep)
  end

  def to_string(%__MODULE__{kind: kind, cookbook: cookbook, segments: segments, source: source}),
    do: id(kind, cookbook, segments) <> format_source(source)

  @doc """
  Builds the canonical qualified id of a recipe or step: `id(:step,
  "cb_std", ["setup", "credo"])` is `"cb_std:setup:credo"`. `segments` may
  also be a `/`-joined internal id (`"setup/credo"`).
  """
  @spec id(kind(), String.t(), [String.t()] | String.t()) :: String.t()
  def id(kind, cookbook, segments) when is_binary(segments),
    do: id(kind, cookbook, String.split(segments, "/"))

  def id(kind, cookbook, segments) do
    sep = separator(kind)
    cookbook <> sep <> Enum.join(segments, sep)
  end

  @doc "The separator of a kind: `/` for a recipe, `:` for a step."
  @spec separator(kind()) :: String.t()
  def separator(:recipe), do: "/"
  def separator(:step), do: ":"

  @doc "The internal id of a ref's segments: `/`-joined, as a file path."
  @spec path(t()) :: String.t()
  def path(%__MODULE__{segments: segments}), do: Enum.join(segments, "/")

  @doc "True when `package` names a package in a private repo (`org.pkg`)."
  @spec repo_package?(String.t()) :: boolean()
  def repo_package?(package), do: String.contains?(package, ".")

  # -- classification ----------------------------------------------------

  defp split(string) do
    case String.split(String.trim(string), "@", parts: 2) do
      [name] -> {name, nil}
      [name, spec] -> {name, spec}
    end
  end

  defp classify("", invalid), do: invalid.("an address is empty")

  defp classify("." <> _ = name, invalid), do: relative(name, invalid)

  defp classify("/" <> rest = name, invalid) do
    with :ok <- one_separator(name, invalid),
         {:ok, segments} <- segments(rest, "/", invalid) do
      {:ok, %__MODULE__{kind: :recipe, scope: :root, segments: segments}}
    end
  end

  defp classify(":" <> rest = name, invalid) do
    with :ok <- one_separator(name, invalid),
         {:ok, segments} <- segments(rest, ":", invalid) do
      {:ok, %__MODULE__{kind: :step, scope: :root, segments: segments}}
    end
  end

  defp classify(name, invalid) do
    with :ok <- one_separator(name, invalid) do
      case :binary.match(name, ["/", ":"]) do
        :nomatch ->
          if valid_name?(name),
            do: {:ok, %__MODULE__{scope: :search, segments: [name]}},
            else: invalid.(name_reason(name))

        {at, 1} ->
          sep = binary_part(name, at, 1)
          cookbook = binary_part(name, 0, at)
          rest = binary_part(name, at + 1, byte_size(name) - at - 1)
          qualified(cookbook, kind_of(sep), rest, invalid)
      end
    end
  end

  defp qualified(cookbook, kind, rest, invalid) do
    cond do
      not valid_name?(cookbook) ->
        invalid.("cookbook names are lowercase [a-z0-9_]")

      cookbook == "hex" and kind == :recipe ->
        invalid.("hex is a step cookbook; a Hex package is written hex:<package>")

      cookbook == "hex" ->
        if Regex.match?(@hex_package, rest),
          do:
            {:ok, %__MODULE__{kind: :step, scope: :qualified, cookbook: "hex", segments: [rest]}},
          else: invalid.("a hex: address names one package, e.g. hex:oban or hex:org.pkg")

      true ->
        with {:ok, segments} <- segments(rest, separator(kind), invalid) do
          {:ok,
           %__MODULE__{kind: kind, scope: :qualified, cookbook: cookbook, segments: segments}}
        end
    end
  end

  # "./x", "../x", "../../x", and the reserved ".:x", "..:x".
  defp relative(name, invalid) do
    case climb(name) do
      {up, {:recipe, path}} ->
        with :ok <- one_separator(name, invalid),
             {:ok, segments} <- segments(path, "/", invalid) do
          {:ok, %__MODULE__{kind: :recipe, scope: :relative, up: up, segments: segments}}
        end

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

      bad = Enum.find(segments, &(not valid_name?(&1))) ->
        invalid.(name_reason(bad))

      true ->
        {:ok, segments}
    end
  end

  defp valid_name?(name), do: Regex.match?(@name, name)

  defp name_reason(name),
    do: "#{inspect(name)} is not a name; names are lowercase [a-z0-9_]"

  defp kind_of("/"), do: :recipe
  defp kind_of(":"), do: :step

  # -- sources ------------------------------------------------------------

  defp attach_source(ref, nil, _invalid), do: {:ok, ref}

  defp attach_source(%__MODULE__{cookbook: "hex", segments: [package]} = ref, spec, invalid) do
    with {:ok, source} <- parse_spec(invalid, package, spec), do: {:ok, %{ref | source: source}}
  end

  defp attach_source(%__MODULE__{kind: :recipe}, _spec, invalid),
    do: invalid.("a recipe address takes no @ source; add its cookbook to mix.exs instead")

  defp attach_source(%__MODULE__{segments: segments}, spec, invalid) do
    invalid.(
      "only a hex: address takes an @ source; for a Hex package write " <>
        inspect("hex:" <> List.last(segments) <> "@" <> spec)
    )
  end

  # The spec after `@`, kept verbatim. Mirrors
  # Igniter.Project.Deps.determine_dep_type_and_version!/2.
  defp parse_spec(invalid, package, spec) do
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

  @doc false
  def format_source([]), do: ""
  def format_source(version: requirement), do: "@" <> requirement
  def format_source(github: repo), do: "@github:" <> repo
  def format_source(github: repo, ref: ref), do: "@github:" <> repo <> "@" <> ref
  def format_source(git: url), do: "@git:" <> url
  def format_source(path: path), do: "@path:" <> path
end
