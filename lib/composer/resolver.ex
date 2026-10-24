defmodule Composer.Resolver do
  @moduledoc """
  Resolves references and expands recipes into one flat, acyclic,
  de-duplicated step list for `Composer.Runner`.

  ## Resolving a step reference

  A bare string in a recipe names a step:

    0. In a recipe, a cookbook part that is one of the recipe's own
       `aliases` is first replaced by the real cookbook name
       (`"lab:auth/passkeys"` with `lab: "cc_lab"` is
       `"cc_lab:auth/passkeys"`); errors show the reference as
       written, with the alias noted. Aliases never apply inside an
       included recipe, nor to references given on the command line. An
       alias that is the name of an installed cookbook is an error.
    1. `"cookbook:path"` is looked up exactly. An unknown cookbook is an
       error that suggests adding the package that ships it.
    2. An unqualified `"path"` is looked up first in the referring
       recipe's own cookbook (on the command line, the current project's
       cookbook).
    3. Otherwise every cookbook is searched. Exactly one match resolves to
       it; more than one is an `:ambiguous` error listing every candidate.
       No match, for a name without a `/`, is the Hex package of that name
       (`"oban"` is `"hex:oban"`) - unless the name is very close to an
       existing step id, which is reported as a likely typo instead.
    4. `"hex:pkg"` (or `"hex:org.pkg"` for a private repo) adds the package
       to `mix.exs` and runs its own installer, if it ships one. Its `@`
       source (`"hex:pkg@path:../pkg"`, see `Composer.Ref`) and the entry's
       options (`argv`, `only`, `runtime`, a source and git options) are
       carried into one `{:install, package, opts}` step, whose `opts` are
       canonical (see `Composer.Runner`). An unqualified name that falls
       back to Hex keeps its options; one that names a step must not have
       package options (`{:dep_opts_on_step, ...}`).

  A step in the referring cookbook wins over a Hex package of the same name,
  so an unqualified name is never ambiguous with `hex:`.

  `{:use, ref}` names a recipe, `"cookbook:chapter/name"`. An unqualified
  name without a `/` (`{:use, "base"}`) is the recipe of that name in the
  same chapter as the referring recipe; nothing outside the chapter can match
  it. Any other reference is resolved like a step reference, except that
  there is no Hex fallback.

  ## Entries

  Every leaf becomes an entry:

      %{ref: "cb_std:setup/credo", label: "cb_std:setup/credo",
        step: {:module, Composer.CbStd.Steps.Setup.Credo},
        origin: "my_app:phx/app", gates: [:dev_tools], if: nil, meta: %Composer.Step.Meta{}}

  `origin` is the recipe the step came from, `gates` the `if:` flags of the
  includes it was reached through, and `if` its own flag. `step` is the
  internal form the runner applies. An install's `ref` is always
  `"hex:pkg"`, whatever its source, so `requires: ["hex:pkg"]` matches it
  by name; its `label` shows the source and installer argv
  (`"hex:my_lib (path ../my_lib)"`). `alias` is the cookbook alias the
  reference was written with (`"lab"`), or `nil`; `ref` and `label` always
  use the real cookbook name.

  The result also lists the recipes visited, root first, as
  `%Composer.Recipe{}` structs; `declared_flags/1` collects their flags.

  ## Rules

    * **Include-once.** A recipe is expanded at most once per resolution;
      later includes of it are no-ops. A diamond is not a cycle.
    * **No cycles.** Re-entering a recipe that is still being expanded is a
      `{:cycle, path}` error, with the full `cookbook:path` chain.
    * **De-duplication.** A step equal to an earlier one is dropped (first
      occurrence wins) and reported in `duplicates`. Equality uses the
      resolved step, so `"setup/credo"` and `"cb_std:setup/credo"` are
      duplicates. Steps that differ only in their `if:` are distinct.
    * **One install per package.** Installs of one package with different
      options (argv, source or dep options, or none against some) are a
      `{:conflicting_install, package, [{origin, label}, ...]}` error,
      whatever their `if:` flags: the runner adds one dependency per
      package. Identical ones are de-duplicated as above.

  ## Flags

  `flags: :all` (the default) follows every gated include, for validation,
  listing and building the flag schema. `flags: keyword` follows a gated
  include only when its flag is true; a skipped include is not marked as
  expanded, so a later ungated include of it still expands. Leaf `if:`
  flags are applied by `active/2`.
  """

  alias Composer.{Recipe, Ref, Cookbook}

  @type entry :: %{
          ref: String.t() | nil,
          label: String.t(),
          step: Composer.Runner.step(),
          origin: String.t() | nil,
          gates: [atom()],
          if: atom() | nil,
          alias: String.t() | nil,
          meta: Composer.Step.Meta.t() | nil
        }

  @type result :: %{
          root: String.t(),
          steps: [entry()],
          duplicates: [entry()],
          gates: [atom()],
          recipes: [Recipe.t()]
        }

  @type warning ::
          {:phase_order, entry(), entry()}
          | {:provides_overlap, atom(), [entry()]}
          | {:conflict, entry(), atom(), entry()}
          | {:requires_order, entry(), String.t()}

  @typo_threshold 0.85

  # -- public API ---------------------------------------------------------

  @doc """
  Resolves recipe `ref` and expands it.

  ## Options

    * `:flags` - `:all` (default) or a keyword of flag values
    * `:context` - the cookbook name an unqualified `ref` is looked up in
      first, normally the current project's cookbook
  """
  @spec resolve_recipe([Cookbook.t()], String.t(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def resolve_recipe(cookbooks, ref, opts \\ []) do
    index = index(cookbooks)

    with {:ok, root} <- find_recipe(index, ref, opts[:context], nil) do
      state = %{
        index: index,
        flags: Keyword.get(opts, :flags, :all),
        stack: [],
        done: MapSet.new(),
        entries: [],
        gates: [],
        visited: [],
        chapters: %{}
      }

      with {:ok, state} <- visit(root, [], state),
           {:ok, {steps, duplicates}} <- dedupe(Enum.reverse(state.entries)) do
        {:ok,
         %{
           root: root,
           steps: steps,
           duplicates: duplicates,
           gates: Enum.uniq(Enum.reverse(state.gates)),
           recipes: Enum.reverse(state.visited)
         }}
      end
    end
  end

  @doc """
  Resolves step references from the command line into entries, in order.

  ## Options

    * `:context` - as for `resolve_recipe/3`
    * `:argv` - arguments passed to every step (from `--`); for a Hex
      package, its installer's arguments
  """
  @spec resolve_steps([Cookbook.t()], [String.t()], keyword()) ::
          {:ok, [entry()]} | {:error, term()}
  def resolve_steps(cookbooks, refs, opts \\ []) do
    index = index(cookbooks)
    argv = Keyword.get(opts, :argv, [])

    refs
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      case find_step(index, ref, opts[:context], nil) do
        {:ok, found} -> {:cont, {:ok, [leaf(found, nil, [], nil, argv: argv) | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} ->
        with {:ok, {kept, _dropped}} <- dedupe(Enum.reverse(entries)), do: {:ok, kept}

      error ->
        error
    end
  end

  @doc """
  Resolves one step reference to its metadata or Hex package, without
  building an entry. Used by `mix composer.step.show`.
  """
  @spec find_step([Cookbook.t()], String.t(), String.t() | nil) ::
          {:ok, {:step, Composer.Step.Meta.t()} | {:hex, String.t()}} | {:error, term()}
  def find_step(cookbooks, ref, context) when is_list(cookbooks) do
    case find_step(index(cookbooks), ref, context, nil) do
      {:ok, {:module, meta}} -> {:ok, {:step, meta}}
      {:ok, {:install, package, _source}} -> {:ok, {:hex, package}}
      error -> error
    end
  end

  @doc """
  Resolves one recipe reference to its qualified id.
  """
  @spec find_recipe([Cookbook.t()], String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def find_recipe(cookbooks, ref, context) when is_list(cookbooks) do
    find_recipe(index(cookbooks), ref, context, nil)
  end

  @doc """
  Resolves every recipe with `flags: :all`, returning the first error.

  Pass `only: [cookbook_name]` to check some cookbooks' recipes only;
  references are still resolved against all of `cookbooks`.
  """
  @spec validate_all([Cookbook.t()], keyword()) :: :ok | {:error, term()}
  def validate_all(cookbooks, opts \\ []) do
    only = opts[:only]

    cookbooks
    |> Enum.filter(&(only == nil or &1.name in only))
    |> Enum.flat_map(fn cookbook ->
      Enum.map(Cookbook.recipes(cookbook), &Ref.id(cookbook.name, &1))
    end)
    |> Enum.reduce_while(:ok, fn ref, :ok ->
      case resolve_recipe(cookbooks, ref, flags: :all) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Returns every flag a resolved recipe understands: the include gates plus
  the leaf `if:` flags.
  """
  @spec flags(result() | [entry()]) :: [atom()]
  def flags(%{steps: entries, gates: gates}), do: Enum.uniq(gates ++ flags(entries))

  def flags(entries) when is_list(entries),
    do: entries |> Enum.flat_map(&List.wrap(&1.if)) |> Enum.uniq()

  @doc """
  Returns the flags declared (in `flags:`) by every recipe a resolution
  visited, root first. With `flags: :all`, these are all the `--flag`s the
  root recipe accepts.
  """
  @spec declared_flags(result()) :: keyword(String.t())
  def declared_flags(%{recipes: recipes}) do
    recipes |> Enum.flat_map(& &1.flags) |> Enum.uniq_by(&elem(&1, 0))
  end

  @doc "Drops entries whose own `if:` flag is off in `opts`."
  @spec active([entry()], keyword()) :: [entry()]
  def active(entries, opts) do
    Enum.filter(entries, fn
      %{if: nil} -> true
      %{if: flag} -> Keyword.get(opts, flag, false) == true
    end)
  end

  @doc "Returns the runner steps of `entries`."
  @spec steps([entry()]) :: [Composer.Runner.step()]
  def steps(entries), do: Enum.map(entries, & &1.step)

  @doc """
  Returns advisory warnings for an ordered list of entries:

    * `{:phase_order, entry, earlier}` - `entry`'s phase comes before the
      phase of `earlier`, a step listed ahead of it
    * `{:provides_overlap, capability, entries}` - several steps provide the
      same capability
    * `{:conflict, entry, capability, other}` - `entry` conflicts with a
      capability that `other` provides
    * `{:requires_order, entry, ref}` - `entry` requires step `ref`, which
      is not listed earlier
  """
  @spec warnings([entry()]) :: [warning()]
  def warnings(entries) do
    phase_order(entries) ++ overlaps(entries) ++ conflicts(entries) ++ requires_order(entries)
  end

  @doc """
  Checks each of `recipe`'s own entries on its own, as resolving it would,
  and returns every error found (one per bad entry), in order: a step or
  package reference, with the recipe's aliases expanded and its cookbook
  first, or a `{:use, ...}` target. An alias that hides an installed
  cookbook comes first. Included recipes are not followed; see
  `resolve_recipe/3` for what only the whole tree shows (cycles,
  conflicting installs).

  `cookbooks` may be an index from `index/1`, to check many recipes.
  """
  @spec check_entries([Cookbook.t()] | index(), Recipe.t()) :: [term()]
  def check_entries(cookbooks, %Recipe{} = recipe) do
    index = index(cookbooks)

    shadow =
      case shadowing(recipe, index) do
        :ok -> []
        {:error, reason} -> [reason]
      end

    entries =
      for entry <- recipe.steps,
          {:error, reason} <- [check_entry(entry, recipe, index)],
          do: reason

    shadow ++ entries
  end

  @doc """
  Returns `recipe`'s own `{:use, ...}` entries as `{written, result}`, in
  order, where `result` is `{:ok, recipe_id}` or `{:error, reason}`.

  `cookbooks` may be an index from `index/1`.
  """
  @spec included([Cookbook.t()] | index(), Recipe.t()) ::
          [{String.t(), {:ok, String.t()} | {:error, term()}}]
  def included(cookbooks, %Recipe{} = recipe) do
    index = index(cookbooks)

    for entry <- recipe.steps,
        written = use_ref(entry),
        is_binary(written),
        do: {written, find_included(index, written, recipe)}
  end

  defp use_ref({:use, ref}), do: ref
  defp use_ref({:use, ref, _opts}), do: ref
  defp use_ref(_entry), do: nil

  defp check_entry({:use, _ref} = entry, recipe, index), do: check_use(entry, recipe, index)

  defp check_entry({:use, _ref, _opts} = entry, recipe, index),
    do: check_use(entry, recipe, index)

  defp check_entry(ref, recipe, index) when is_binary(ref),
    do: check_entry({ref, []}, recipe, index)

  defp check_entry({ref, opts}, recipe, index) when is_binary(ref) and is_list(opts) do
    with {:ok, _found, _via} <- lookup_step(index, ref, opts, recipe), do: :ok
  end

  defp check_entry(_entry, _recipe, _index), do: :ok

  defp check_use(entry, recipe, index) do
    with {:ok, _id} <- find_included(index, use_ref(entry), recipe), do: :ok
  end

  # -- index --------------------------------------------------------------

  @typedoc "Cookbooks prepared for lookups, from `index/1`."
  @opaque index :: %{cookbooks: [Cookbook.t()], by_name: map(), steps: map(), recipes: map()}

  @doc """
  Prepares `cookbooks` for lookups, for `check_entries/2` and
  `included/2` over many recipes.
  """
  @spec index([Cookbook.t()] | index()) :: index()
  def index(%{by_name: _} = index), do: index

  def index(cookbooks) when is_list(cookbooks) do
    %{
      cookbooks: cookbooks,
      by_name: Map.new(cookbooks, &{&1.name, &1}),
      steps:
        for %{kind: :code} = cookbook <- cookbooks, into: %{} do
          {cookbook.name, Map.new(Cookbook.steps(cookbook), &{&1.id, &1})}
        end,
      recipes:
        for %{kind: kind} = cookbook <- cookbooks, kind != :virtual, into: %{} do
          {cookbook.name, Cookbook.recipes(cookbook)}
        end
    }
  end

  # -- step references ----------------------------------------------------

  defp find_step(index, string, context, origin) do
    with {:ok, ref} <- Ref.parse(string) do
      case ref do
        %Ref{cookbook: "hex", path: package, source: source} ->
          {:ok, {:install, package, source}}

        %Ref{cookbook: nil} ->
          find_unqualified_step(index, ref, string, context, origin)

        %Ref{cookbook: name, path: path} ->
          cond do
            not Map.has_key?(index.by_name, name) ->
              {:error, {:unknown_cookbook, name, string, origin, Map.keys(index.by_name)}}

            meta = index.steps[name][path] ->
              {:ok, {:module, meta}}

            true ->
              {:error, {:missing_step, string, origin, step_suggestions(index, path)}}
          end
      end
    end
  end

  defp find_unqualified_step(index, %Ref{path: path} = ref, string, context, origin) do
    own = context && index.steps[context][path]

    if own do
      {:ok, {:module, own}}
    else
      case for({_name, steps} <- index.steps, meta = steps[path], do: meta) do
        [meta] ->
          {:ok, {:module, meta}}

        [_ | _] = metas ->
          {:error,
           {:ambiguous, :step, string, origin, metas |> Enum.map(& &1.ref) |> Enum.sort()}}

        [] ->
          suggestions = step_suggestions(index, path)

          cond do
            Ref.nested?(ref) -> {:error, {:missing_step, string, origin, suggestions}}
            suggestions != [] -> {:error, {:typo, string, origin, suggestions}}
            true -> {:ok, {:install, path, []}}
          end
      end
    end
  end

  # Close names, so a typo is reported instead of becoming a Hex lookup.
  defp step_suggestions(index, path) do
    for({_name, steps} <- index.steps, {id, meta} <- steps, do: {meta.ref, id})
    |> ranked(path)
  end

  # The refs whose ids are close to `path`, closest first. An id that moved
  # into or out of a group outranks a spelling match.
  defp ranked(candidates, path) do
    for({ref, id} <- candidates, score = closeness(id, path), do: {score, ref})
    |> Enum.sort_by(fn {score, ref} -> {-score, ref} end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
  end

  defp closeness(id, path) do
    if regrouped?(id, path) do
      2.0
    else
      score = max(String.jaro_distance(id, path), String.jaro_distance(Path.basename(id), path))
      if score > @typo_threshold, do: score
    end
  end

  # gigalixir/libcluster -> cluster/gigalixir/libcluster and
  # pg_extensions -> pg/extensions, or the reverse.
  defp regrouped?(id, path) do
    String.ends_with?(id, "/" <> path) or String.ends_with?(path, "/" <> id) or
      String.replace(id, "/", "_") == String.replace(path, "/", "_")
  end

  defp similar?(a, b), do: String.jaro_distance(a, b) > @typo_threshold

  # -- recipe references -------------------------------------------------

  defp find_recipe(index, string, context, origin) do
    with {:ok, ref} <- Ref.parse(string) do
      case ref do
        %Ref{cookbook: nil, path: path} ->
          if context && path in Map.get(index.recipes, context, []) do
            {:ok, Ref.id(context, path)}
          else
            case for({name, ids} <- index.recipes, path in ids, do: Ref.id(name, path)) do
              [id] -> {:ok, id}
              [_ | _] = ids -> {:error, {:ambiguous, :recipe, string, origin, Enum.sort(ids)}}
              [] -> {:error, {:missing_recipe, string, origin, recipe_suggestions(index, path)}}
            end
          end

        %Ref{cookbook: name, path: path} ->
          cond do
            not Map.has_key?(index.by_name, name) ->
              {:error, {:unknown_cookbook, name, string, origin, Map.keys(index.by_name)}}

            path in Map.get(index.recipes, name, []) ->
              {:ok, Ref.id(name, path)}

            true ->
              {:error, {:missing_recipe, string, origin, recipe_suggestions(index, path)}}
          end
      end
    end
  end

  defp recipe_suggestions(index, path) do
    all = for {name, ids} <- index.recipes, id <- ids, do: {Ref.id(name, id), id}

    case ranked(all, path) do
      [] -> all |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      close -> close
    end
  end

  # An unqualified {:use, "name"} is the recipe `name` in the referring
  # recipe's chapter.
  defp find_in_chapter(index, name, recipe) do
    id = recipe.chapter <> "/" <> name
    ids = Map.get(index.recipes, recipe.cookbook, [])

    if id in ids do
      {:ok, Ref.id(recipe.cookbook, id)}
    else
      siblings =
        for sibling <- ids,
            Path.dirname(sibling) == recipe.chapter,
            do: {Ref.id(recipe.cookbook, sibling), Path.basename(sibling)}

      suggestions =
        case for({ref, sibling} <- siblings, similar?(sibling, name), do: ref) do
          [] -> Enum.map(siblings, &elem(&1, 0))
          close -> close
        end

      {:error, {:missing_recipe, name, recipe.ref, Enum.sort(suggestions)}}
    end
  end

  # -- walk ---------------------------------------------------------------

  defp visit(id, gates, state) do
    if id in state.stack do
      path = state.stack |> Enum.reverse() |> Enum.drop_while(&(&1 != id))
      {:error, {:cycle, path ++ [id]}}
    else
      with {:ok, recipe, state} <- load(id, state),
           :ok <- shadowing(recipe, state.index) do
        state = %{state | stack: [id | state.stack], visited: [recipe | state.visited]}

        recipe.steps
        |> Enum.reduce_while({:ok, state}, fn entry, {:ok, state} ->
          case step(entry, recipe, gates, state) do
            {:ok, state} -> {:cont, {:ok, state}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, state} ->
            {:ok, %{state | stack: tl(state.stack), done: MapSet.put(state.done, id)}}

          error ->
            error
        end
      end
    end
  end

  # Each chapter file is evaluated once per resolution.
  defp load(id, state) do
    %Ref{cookbook: name, path: path} = Ref.parse!(id)
    cookbook = Map.fetch!(state.index.by_name, name)

    case Cookbook.recipe_path(cookbook, path) do
      nil ->
        {:error, {:missing_recipe, id, nil, []}}

      file ->
        with {:ok, loaded, state} <- load_chapter(file, name, state),
             {:ok, recipe} <- Recipe.Chapter.pick(loaded, file, name, Path.basename(path)) do
          {:ok, recipe, state}
        end
    end
  end

  defp load_chapter(file, name, state) do
    case state.chapters do
      %{^file => loaded} ->
        {:ok, loaded, state}

      _ ->
        with {:ok, loaded} <- Recipe.Chapter.load_all(file, name) do
          {:ok, loaded, %{state | chapters: Map.put(state.chapters, file, loaded)}}
        end
    end
  end

  # An alias may not hide an installed cookbook, used or not.
  defp shadowing(recipe, index) do
    case Enum.find(recipe.aliases, &Map.has_key?(index.by_name, Atom.to_string(elem(&1, 0)))) do
      nil -> :ok
      {name, _target} -> {:error, {:alias_shadows_cookbook, recipe.ref, name}}
    end
  end

  # Replaces an aliased cookbook part of a reference written in `recipe`
  # with the real cookbook name. Returns the string to look up and, for an
  # aliased reference, `{alias, target, written}` for errors and display.
  defp expand(string, recipe) do
    with {:ok, %Ref{cookbook: name, path: path}} <- Ref.parse(string),
         target when is_binary(target) <- Recipe.alias_target(recipe, name) do
      {Ref.id(target, path), {name, target, string}}
    else
      _ -> {string, nil}
    end
  end

  # Rewrites a lookup error of an expanded reference to show it as written.
  defp via_alias({:error, reason}, {name, target, written}) do
    case reason do
      {:unknown_cookbook, ^target, _ref, origin, known} ->
        {:error, {:unknown_alias_target, written, name, target, origin, known}}

      reason ->
        {:error, {:via_alias, written, name, target, reason}}
    end
  end

  defp via_alias(result, _via), do: result

  defp step({:use, ref}, recipe, gates, state), do: include(ref, nil, recipe, gates, state)

  defp step({:use, ref, opts}, recipe, gates, state),
    do: include(ref, opts[:if], recipe, gates, state)

  defp step({kind, task}, recipe, gates, state) when kind in [:task, :queue],
    do: step({kind, task, []}, recipe, gates, state)

  defp step({kind, task, argv}, recipe, gates, state) when kind in [:task, :queue],
    do: {:ok, emit(state, task_entry(kind, task, argv, nil, recipe.ref, gates))}

  defp step({kind, task, argv, opts}, recipe, gates, state) when kind in [:task, :queue],
    do: {:ok, emit(state, task_entry(kind, task, argv, opts[:if], recipe.ref, gates))}

  defp step(ref, recipe, gates, state) when is_binary(ref),
    do: step({ref, []}, recipe, gates, state)

  defp step({ref, opts}, recipe, gates, state) when is_binary(ref) do
    with {:ok, found, via} <- lookup_step(state.index, ref, opts, recipe) do
      entry = leaf(found, recipe.ref, gates, opts[:if], opts)
      {:ok, emit(state, %{entry | alias: via && elem(via, 0)})}
    end
  end

  # Finds the step or package a `{ref, opts}` entry of `recipe` names,
  # with the recipe's aliases expanded.
  defp lookup_step(index, ref, opts, recipe) do
    {lookup, via} = expand(ref, recipe)
    package_keys = for {key, _} <- opts, key in Recipe.package_options(), do: key

    case via_alias(find_step(index, lookup, recipe.cookbook, recipe.ref), via) do
      {:ok, {:module, meta}} when package_keys != [] ->
        {:error, {:dep_opts_on_step, ref, meta.ref, recipe.ref, package_keys}}

      {:ok, found} ->
        {:ok, found, via}

      error ->
        error
    end
  end

  defp include(ref, flag, recipe, gates, state) do
    if flag && state.flags != :all && Keyword.get(state.flags, flag, false) != true do
      {:ok, state}
    else
      with {:ok, id} <- find_included(state.index, ref, recipe) do
        if MapSet.member?(state.done, id) do
          {:ok, state}
        else
          state = if flag, do: %{state | gates: [flag | state.gates]}, else: state
          visit(id, gates ++ List.wrap(flag), state)
        end
      end
    end
  end

  defp find_included(index, ref, recipe) do
    case Ref.parse(ref) do
      {:ok, %Ref{cookbook: nil, path: name} = parsed} ->
        if Ref.nested?(parsed),
          do: find_recipe(index, ref, recipe.cookbook, recipe.ref),
          else: find_in_chapter(index, name, recipe)

      _ ->
        {lookup, via} = expand(ref, recipe)
        via_alias(find_recipe(index, lookup, recipe.cookbook, recipe.ref), via)
    end
  end

  defp emit(state, entry), do: %{state | entries: [entry | state.entries]}

  # `opts` are the entry's options; only argv: and the package options
  # are read here.
  defp leaf({:module, meta}, origin, gates, flag, opts) do
    argv = Keyword.get(opts, :argv, [])
    step = if argv == [], do: {:module, meta.module}, else: {:module, meta.module, argv}

    %{
      ref: meta.ref,
      label: Enum.join([meta.ref | argv], " "),
      step: step,
      origin: origin,
      gates: gates,
      if: flag,
      alias: nil,
      meta: meta
    }
  end

  defp leaf({:install, package, source}, origin, gates, flag, opts) do
    install_opts = install_opts(source, opts)
    # Hex package names come from recipes and the command line, which the
    # user controls; the runner needs them as atoms.
    step = {:install, String.to_atom(package), install_opts}

    %{
      ref: "hex:" <> package,
      label: Composer.Runner.install_label(package, install_opts),
      step: step,
      origin: origin,
      gates: gates,
      if: flag,
      alias: nil,
      meta: nil
    }
  end

  # The canonical opts of an install step, so equal options compare equal:
  # argv, source, dep in that order, empty ones dropped; the source kind
  # first, then git options by key; only: as a sorted list. The reference's
  # @ source and a keyword source never both appear (Composer.Recipe).
  defp install_opts(ref_source, opts) do
    {kind, git} =
      (ref_source ++ Keyword.take(opts, Recipe.source_keys() ++ Recipe.git_keys()))
      |> Enum.split_with(&(elem(&1, 0) in Recipe.source_keys()))

    dep =
      opts
      |> Keyword.take([:only, :runtime])
      |> Enum.map(fn
        {:only, envs} -> {:only, envs |> List.wrap() |> Enum.uniq() |> Enum.sort()}
        other -> other
      end)
      |> Enum.sort()

    Enum.reject(
      [argv: Keyword.get(opts, :argv, []), source: kind ++ Enum.sort(git), dep: dep],
      &(elem(&1, 1) == [])
    )
  end

  defp task_entry(kind, task, argv, flag, origin, gates) do
    label = {kind, task, argv} |> Macro.escape() |> Macro.to_string()

    %{
      ref: nil,
      label: label,
      step: {kind, task, argv},
      origin: origin,
      gates: gates,
      if: flag,
      alias: nil,
      meta: nil
    }
  end

  # Conflicting installs are checked across if: flags too: both flags can
  # be on at once, and the runner adds one dependency per package.
  defp dedupe(entries) do
    entries
    |> Enum.reduce_while({[], [], MapSet.new(), %{}}, fn entry, {kept, dropped, seen, installs} ->
      case check_install(entry, installs) do
        {:conflict, first, package} ->
          installs = for e <- [first, entry], do: {e.origin, e.label}
          {:halt, {:error, {:conflicting_install, Atom.to_string(package), installs}}}

        installs ->
          key = {entry.step, entry.if}

          if MapSet.member?(seen, key),
            do: {:cont, {kept, [entry | dropped], seen, installs}},
            else: {:cont, {[entry | kept], dropped, MapSet.put(seen, key), installs}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      {kept, dropped, _seen, _installs} -> {:ok, {Enum.reverse(kept), Enum.reverse(dropped)}}
    end
  end

  # Remembers the first install of each package.
  defp check_install(%{step: {:install, package, _opts} = step} = entry, installs) do
    case installs do
      %{^package => %{step: ^step}} -> installs
      %{^package => first} -> {:conflict, first, package}
      _ -> Map.put(installs, package, entry)
    end
  end

  defp check_install(_entry, installs), do: installs

  # -- warnings -----------------------------------------------------------

  # Each step is compared with the latest phase reached so far, so one step
  # placed too late is reported once rather than against every step after it.
  defp phase_order(entries) do
    phases = Composer.Facets.phases()

    entries
    |> Enum.reduce({nil, []}, fn entry, {latest, acc} ->
      case {phase_rank(entry, phases), latest} do
        {nil, _} -> {latest, acc}
        {rank, {top, earlier}} when rank < top -> {latest, [{:phase_order, entry, earlier} | acc]}
        {rank, {top, _}} when rank == top -> {latest, acc}
        {rank, _} -> {{rank, entry}, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp phase_rank(%{meta: %{phase: phase}}, phases) when phase != nil,
    do: Enum.find_index(phases, &(&1 == phase))

  defp phase_rank(_entry, _phases), do: nil

  defp overlaps(entries) do
    entries
    |> Enum.flat_map(fn
      %{meta: %{provides: provides}} = entry -> Enum.map(provides, &{&1, entry})
      _ -> []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_capability, providers} -> length(providers) > 1 end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {capability, providers} -> {:provides_overlap, capability, providers} end)
  end

  defp conflicts(entries) do
    for %{meta: %{conflicts: conflicts}} = entry <- entries,
        capability <- conflicts,
        %{meta: %{provides: provides}} = other <- entries,
        other != entry,
        capability in provides,
        do: {:conflict, entry, capability, other}
  end

  defp requires_order(entries) do
    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{meta: %{requires: requires}} = entry, index} ->
        earlier = Enum.take(entries, index)

        for ref when is_binary(ref) <- requires,
            not Enum.any?(earlier, &satisfies?(&1, ref)),
            do: {:requires_order, entry, ref}

      _ ->
        []
    end)
  end

  defp satisfies?(%{ref: nil}, _ref), do: false

  defp satisfies?(%{ref: ref}, required) do
    if String.contains?(required, ":"),
      do: ref == required,
      else: String.ends_with?(ref, ":" <> required)
  end
end
