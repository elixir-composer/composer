defmodule Composer.Facets do
  @moduledoc """
  The controlled facet vocabulary that steps declare with `use Composer.Step`.

  Facets describe a step instead of encoding meaning in its module path:

    * `action` - what the step does: #{inspect([:add, :remove, :gen, :config, :patch, :debug])}
    * `frameworks` - the frameworks it targets
    * `capability` - the capabilities it adds
    * `phase` - an advisory position in a run (list order still decides)
    * `stability` - how settled the step is

  An unknown facet *value* is a compile-time warning, never an error, so a
  cookbook can run ahead of composer's vocabulary. A value of the wrong
  *type* (for example `tags: "x"`) is an error.

  `requires` entries are checked before a run:

    * a step that should run earlier: qualified (`"cb_std:cluster:libcluster"`),
      root (`":cluster:libcluster"`, in the step's own cookbook) or
      `"hex:pkg"`. A bare or relative address is an error; a qualified one
      in the old syntax (`"cb_std:cluster/libcluster"`) is a warning, which
      `mix composer.cookbook.lint --fix` rewrites
    * `{:executable, "bun"}` - an executable on `PATH`
    * `{:package, :phoenix, "~> 1.8"}` - a version requirement on a dependency
      the target app declares
  """

  @action [:add, :remove, :gen, :config, :patch, :debug]
  @frameworks [:phoenix, :liveview, :ash, :astral, :term_ui, :mob, :jido, :ecto]
  @capability [
    :auth,
    :jobs,
    :deploy,
    :css,
    :testing,
    :devtools,
    :ai,
    :observability,
    :database,
    :assets,
    :icons
  ]
  @phase [:cleanup, :setup, :generate, :finalize]
  @stability [:experimental, :beta, :stable, :deprecated]

  @vocabulary %{
    action: @action,
    frameworks: @frameworks,
    capability: @capability,
    phase: @phase,
    stability: @stability
  }

  # Facets that hold one value; the others hold a list.
  @single [:action, :phase, :stability]
  @strings [:summary, :author, :license, :homepage]

  @known [:tags, :requires, :provides, :conflicts | Map.keys(@vocabulary) ++ @strings]

  @typedoc "A `requires` entry."
  @type requirement ::
          String.t() | {:executable, String.t()} | {:package, atom(), String.t()}

  @doc "Returns the seed vocabulary as `%{facet => [value]}`."
  @spec vocabulary() :: %{atom() => [atom()]}
  def vocabulary, do: @vocabulary

  @doc "Returns the values known for `facet`."
  @spec values(atom()) :: [atom()]
  def values(facet), do: Map.fetch!(@vocabulary, facet)

  @doc "The order of the `phase` facet, earliest first."
  @spec phases() :: [atom()]
  def phases, do: @phase

  @doc "Every option `use Composer.Step` accepts."
  @spec known() :: [atom()]
  def known, do: @known

  @doc """
  Validates and normalizes step options.

  Returns `{:ok, normalized, warnings}`, where `normalized` is a map with
  every known key (list facets default to `[]`, single facets to `nil`), or
  `{:error, message}` for an unknown option or a value of the wrong type.
  Warnings are strings naming each unknown facet value.
  """
  @spec validate(keyword()) :: {:ok, map(), [String.t()]} | {:error, String.t()}
  def validate(opts) when is_list(opts) do
    with :ok <- check_keyword(opts),
         :ok <- check_keys(opts) do
      Enum.reduce_while(@known, {:ok, %{}, []}, fn key, {:ok, acc, warnings} ->
        case normalize(key, Keyword.get(opts, key)) do
          {:ok, value} ->
            warnings = warnings ++ unknown_values(key, value) ++ old_requirements(key, value)
            {:cont, {:ok, Map.put(acc, key, value), warnings}}

          {:error, message} ->
            {:halt, {:error, message}}
        end
      end)
    end
  end

  def validate(other), do: {:error, "step options must be a keyword list, got: #{inspect(other)}"}

  @doc """
  True for a well-formed `requires` entry: a qualified or root step
  address, `"hex:pkg"`, `{:executable, name}` or `{:package, name,
  requirement}`.
  """
  @spec requirement?(term()) :: boolean()
  def requirement?(ref) when is_binary(ref) do
    case Composer.Ref.parse(ref) do
      {:ok, %Composer.Ref{kind: :step, scope: scope, source: []}} -> scope in [:qualified, :root]
      _ -> false
    end
  end

  def requirement?({:executable, name}), do: is_binary(name) and name != ""

  def requirement?({:package, name, requirement}) when is_atom(name) and is_binary(requirement) do
    match?({:ok, _}, Version.parse_requirement(requirement))
  end

  def requirement?(_other), do: false

  defp check_keyword(opts) do
    if Keyword.keyword?(opts),
      do: :ok,
      else: {:error, "step options must be a keyword list, got: #{inspect(opts)}"}
  end

  defp check_keys(opts) do
    case Keyword.keys(opts) -- @known do
      [] ->
        :ok

      unknown ->
        {:error,
         "unknown step option(s) #{Enum.map_join(unknown, ", ", &inspect/1)}. " <>
           "Known options: #{Enum.map_join(@known, ", ", &inspect/1)}"}
    end
  end

  defp normalize(key, nil) when key in @single or key in @strings, do: {:ok, nil}
  defp normalize(_key, nil), do: {:ok, []}

  defp normalize(key, value) when key in @strings do
    if is_binary(value), do: {:ok, value}, else: type_error(key, value, "a string")
  end

  defp normalize(key, value) when key in @single do
    if is_atom(value) and not is_boolean(value),
      do: {:ok, value},
      else: type_error(key, value, "an atom")
  end

  # List facets accept a bare atom as shorthand for a one-element list.
  defp normalize(key, value) when key in [:frameworks, :capability, :provides, :conflicts] do
    atoms = if is_list(value), do: value, else: [value]

    if Enum.all?(atoms, &(is_atom(&1) and not is_boolean(&1))),
      do: {:ok, atoms},
      else: type_error(key, value, "an atom or a list of atoms")
  end

  defp normalize(:tags, tags) when is_list(tags) do
    if Enum.all?(tags, &(is_binary(&1) or (is_atom(&1) and not is_boolean(&1)))),
      do: {:ok, Enum.map(tags, &to_string/1)},
      else: type_error(:tags, tags, "a list of atoms or strings")
  end

  defp normalize(:tags, tags), do: type_error(:tags, tags, "a list of atoms or strings")

  defp normalize(:requires, requires) when is_list(requires) do
    case Enum.reject(requires, &(requirement?(&1) or old_requirement?(&1))) do
      [] ->
        {:ok, requires}

      [bad | _] ->
        {:error,
         "invalid requires entry #{inspect(bad)}. Expected a step address, " <>
           "\"cookbook:path:to:step\" or \":path:to:step\" (in this cookbook), " <>
           "\"hex:pkg\", {:executable, \"name\"} or {:package, :name, \"~> 1.0\"}"}
    end
  end

  defp normalize(:requires, requires), do: type_error(:requires, requires, "a list")

  defp type_error(key, value, expected) do
    {:error, "#{key}: expected #{expected}, got: #{inspect(value)}"}
  end

  # A requirement in the old address syntax still compiles, so that
  # mix composer.cookbook.lint --fix can run and rewrite it.
  # Only the qualified old form (`"cb_std:cluster/libcluster"`): a bare or
  # unqualified one never named one step for sure.
  defp old_requirement?(ref) when is_binary(ref) do
    match?({:error, _}, Composer.Ref.parse(ref)) and
      match?(
        {:ok, %Composer.Ref.Legacy{cookbook: cookbook, source: []}} when is_binary(cookbook),
        Composer.Ref.Legacy.parse(ref)
      )
  end

  defp old_requirement?(_ref), do: false

  defp old_requirements(:requires, requires) do
    for ref <- requires, is_binary(ref), not requirement?(ref) do
      {:ok, %{cookbook: cookbook, path: path}} = Composer.Ref.Legacy.parse(ref)

      "requires #{inspect(ref)} is in the old address syntax; write " <>
        "#{inspect(Composer.Ref.id(:step, cookbook, path))} (mix composer.cookbook.lint --fix rewrites it)"
    end
  end

  defp old_requirements(_key, _value), do: []

  defp unknown_values(key, value) when is_map_key(@vocabulary, key) do
    known = Map.fetch!(@vocabulary, key)

    for v <- List.wrap(value), v not in known do
      "unknown #{key} value #{inspect(v)}. Known values: " <>
        Enum.map_join(known, ", ", &inspect/1)
    end
  end

  defp unknown_values(_key, _value), do: []
end
