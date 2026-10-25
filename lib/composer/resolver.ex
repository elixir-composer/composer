defmodule Composer.Resolver do
  @moduledoc """
  Resolves addresses and expands recipes into one flat, acyclic,
  de-duplicated step list for `Composer.Runner`.

  ## Context

  Every address (see `Composer.Ref`) is resolved against a context:

      %{cookbook: "cb_lab" | nil, chapter: "ash/ui/tailwind" | nil, cli?: boolean}

  In a recipe, the context is the recipe's own cookbook and chapter. On the
  command line it is the current project's cookbook (`nil` when the project
  is not a cookbook), no chapter, and `cli?: true` (see `context/1`).

  | Scope        | Resolves to                                       | Error when                                  |
  |--------------|---------------------------------------------------|---------------------------------------------|
  | `:qualified` | the alias-expanded cookbook and the segments      | unknown cookbook; missing                   |
  | `:root`      | the context cookbook and the segments             | no context cookbook                         |
  | `:relative`  | the context chapter, `up` levels up, + segments   | no chapter (CLI); climbs above `recipes/`; missing |
  | `:search`    | the one recipe or step, in any cookbook, whose last segment matches | not on the CLI; none or several match |

  Relative addresses always stay in the context cookbook. From chapter
  `ash/ui/tailwind`, `./base` is `ash/ui/tailwind/base`, `../buttons` is
  `ash/ui/buttons` and `../../core` is `ash/core`; `../../../core` climbs
  above `recipes/`.

  A resolved recipe address has at least two segments, a chapter and a
  name: `cb_std/echo` is an error, which names the step `cb_std:echo` when
  there is one. Any missing address whose other-kind twin exists says so
  (`{:kind_mismatch, ...}`).

  ## In cookbook source

  Cookbook source never searches and never falls back to Hex. A bare word
  in a recipe is a `{:bare_word, ...}` error listing what it could have
  meant (`"oban"` is not an address; write `"hex:oban"`), so installing
  another cookbook can never change what a recipe means.

  In a recipe, a qualified cookbook part that is one of the recipe's own
  `aliases` is first replaced by the real cookbook name (`"lab:auth:passkeys"`
  with `lab: "cc_lab"` is `"cc_lab:auth:passkeys"`, `"lab/auth/base"` is
  `"cc_lab/auth/base"`); errors show the address as written, with the
  alias noted. Aliases never apply to root or relative addresses, inside an
  included recipe, nor on the command line. An alias that is the name of
  an installed cookbook is an error.

  `"hex:pkg"` (or `"hex:org.pkg"` for a private repo) adds the package to
  `mix.exs` and runs its own installer, if it ships one. Its `@` source
  (`"hex:pkg@path:../pkg"`) and the entry's options (`argv`, `only`,
  `runtime`, a source and git options) are carried into one
  `{:install, package, opts}` step, whose `opts` are canonical (see
  `Composer.Runner`). A step must not have package options
  (`{:dep_opts_on_step, ...}`).

  ## Entries

  The kind of a recipe's entry comes from its address: a recipe address
  (`"./base"`, `{"cb_std/debug/echo", if: :x}`) includes that recipe in
  place, and may only be gated with `if:` (`{:include_options, ...}`); a
  step address (including `hex:`) is a step. `{:use, ...}` is gone: it is
  a `{:use_entry, ...}` error with the rewritten entry.

  Old-syntax addresses (`"cb_std:setup/credo"`, an unqualified `"a/b"`
  step) are `{:old_syntax, ...}` errors naming the new spelling, which
  `mix composer.cookbook.lint --fix` writes.

  Every leaf becomes an entry:

      %{ref: "cb_std:setup:credo", label: "cb_std:setup:credo",
        step: {:module, Composer.CbStd.Steps.Setup.Credo},
        origin: "my_app/phx/app", gates: [:dev_tools], if: nil, meta: %Composer.Step.Meta{}}

  `origin` is the recipe the step came from, `gates` the `if:` flags of the
  includes it was reached through, and `if` its own flag. `step` is the
  internal form the runner applies. An install's `ref` is always
  `"hex:pkg"`, whatever its source, so `requires: ["hex:pkg"]` matches it
  by name; its `label` shows the source and installer argv
  (`"hex:my_lib (path ../my_lib)"`). `alias` is the cookbook alias the
  address was written with (`"lab"`), or `nil`; `ref` and `label` always
  use the real cookbook name. Refs are canonical ids (`Composer.Ref.id/3`).

  The result also lists the recipes visited, root first, as
  `%Composer.Recipe{}` structs; `declared_flags/1` collects their flags.

  ## Rules

    * **Include-once.** A recipe is expanded at most once per resolution;
      later includes of it are no-ops. A diamond is not a cycle.
    * **No cycles.** Re-entering a recipe that is still being expanded is a
      `{:cycle, path}` error, with the full chain of recipe ids.
    * **De-duplication.** A step equal to an earlier one is dropped (first
      occurrence wins) and reported in `duplicates`. Equality uses the
      resolved step, so `":setup:credo"` in a `cb_std` recipe and
      `"cb_std:setup:credo"` are duplicates. Steps that differ only in
      their `if:` are distinct.
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

  @type context :: %{cookbook: String.t() | nil, chapter: String.t() | nil, cli?: boolean()}

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
  Builds a resolution context: from a recipe (its cookbook and chapter), a
  context map (missing keys default), a cookbook name, or `nil`.
  """
  @spec context(Recipe.t() | map() | String.t() | nil) :: context()
  def context(%Recipe{cookbook: cookbook, chapter: chapter}),
    do: %{cookbook: cookbook, chapter: chapter, cli?: false}

  def context(nil), do: %{cookbook: nil, chapter: nil, cli?: false}
  def context(name) when is_binary(name), do: %{cookbook: name, chapter: nil, cli?: false}

  def context(%{} = context),
    do: Map.merge(context(nil), Map.take(context, [:cookbook, :chapter, :cli?]))

  @doc """
  The recipe id that relative `segments`, `up` levels above `chapter`,
  name: `relative("ash/ui", 1, ["core"])` is `{:ok, "ash/core"}`. An
  address that climbs above `recipes/`, or names no chapter, is
  `{:error, :above_root}`.
  """
  @spec relative(String.t(), non_neg_integer(), [String.t()]) ::
          {:ok, String.t()} | {:error, :above_root}
  def relative(chapter, up, segments) do
    base = String.split(chapter, "/")

    if up > length(base) or length(base) - up + length(segments) < 2,
      do: {:error, :above_root},
      else: {:ok, Enum.join(Enum.drop(base, -up) ++ segments, "/")}
  end

  @doc """
  Resolves recipe `ref` and expands it.

  ## Options

    * `:flags` - `:all` (default) or a keyword of flag values
    * `:context` - what `ref` is resolved against (see `context/1`); on
      the command line, `Composer.CLI.context/1`
  """
  @spec resolve_recipe([Cookbook.t()], String.t(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def resolve_recipe(cookbooks, ref, opts \\ []) do
    index = index(cookbooks)

    with {:ok, root} <- find_recipe(index, ref, context(opts[:context]), nil) do
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
  Resolves step addresses from the command line into entries, in order.

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
    context = context(opts[:context])

    refs
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      case find_step(index, ref, context, nil) do
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
  Resolves one step address to its metadata or Hex package, without
  building an entry. Used by `mix composer.step.show` and lint.
  """
  @spec find_step([Cookbook.t()] | index(), String.t(), context() | String.t() | nil) ::
          {:ok, {:step, Composer.Step.Meta.t()} | {:hex, String.t()}} | {:error, term()}
  def find_step(cookbooks, ref, context) do
    case find_step(index(cookbooks), ref, context(context), nil) do
      {:ok, {:module, meta}} -> {:ok, {:step, meta}}
      {:ok, {:install, package, _source}} -> {:ok, {:hex, package}}
      error -> error
    end
  end

  @doc """
  Resolves one recipe address to its canonical id.
  """
  @spec find_recipe([Cookbook.t()] | index(), String.t(), context() | String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def find_recipe(cookbooks, ref, context) do
    find_recipe(index(cookbooks), ref, context(context), nil)
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
      Enum.map(Cookbook.recipes(cookbook), &Ref.id(:recipe, cookbook.name, &1))
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
  and returns every error found (one per bad entry), in order: a step,
  package or include address, with the recipe's aliases expanded, or a
  `{:use, ...}` entry. An alias that hides an installed cookbook comes
  first. Included recipes are not followed; see `resolve_recipe/3` for
  what only the whole tree shows (cycles, conflicting installs).

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
  Returns `recipe`'s own recipe includes as `{written, result}`, in order,
  where `result` is `{:ok, recipe_id}` or `{:error, reason}`.

  `cookbooks` may be an index from `index/1`.
  """
  @spec included([Cookbook.t()] | index(), Recipe.t()) ::
          [{String.t(), {:ok, String.t()} | {:error, term()}}]
  def included(cookbooks, %Recipe{} = recipe) do
    index = index(cookbooks)

    for entry <- recipe.steps,
        written = include_ref(entry),
        is_binary(written),
        do: {written, find_included(index, written, recipe)}
  end

  @doc """
  Resolves an address written in `recipe` (with its aliases and its
  chapter for relative addresses) to the canonical id of the recipe or
  step it names. A `hex:` address is returned as written.
  """
  @spec address_id([Cookbook.t()] | index(), Recipe.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def address_id(cookbooks, %Recipe{} = recipe, string) do
    case entry_target(index(cookbooks), {string, []}, recipe) do
      {:ok, {:include, id, _flag}} -> {:ok, id}
      {:ok, {:step, {:module, meta}, _via}} -> {:ok, meta.ref}
      {:ok, {:step, {:install, _package, _source}, _via}} -> {:ok, string}
      error -> error
    end
  end

  @doc """
  Every recipe and step, in any cookbook, whose last segment is `word`, as
  canonical ids, recipes first.
  """
  @spec search([Cookbook.t()] | index(), String.t()) :: [String.t()]
  def search(cookbooks, word) do
    index = index(cookbooks)

    recipes =
      for {name, ids} <- index.recipes,
          id <- ids,
          Path.basename(id) == word,
          do: Ref.id(:recipe, name, id)

    steps =
      for {_name, steps} <- index.steps,
          {id, meta} <- steps,
          Path.basename(id) == word,
          do: meta.ref

    Enum.sort(recipes) ++ Enum.sort(steps)
  end

  # The address of a recipe-include entry, or nil.
  defp include_ref(entry) do
    case entry do
      string when is_binary(string) -> recipe_address(string)
      {string, opts} when is_binary(string) and is_list(opts) -> recipe_address(string)
      _ -> nil
    end
  end

  defp recipe_address(string) do
    case Ref.parse(string) do
      {:ok, %Ref{kind: :recipe}} -> string
      _ -> nil
    end
  end

  defp check_entry({:use, _} = entry, recipe, index),
    do: {:error, use_entry(index, recipe, entry)}

  defp check_entry({:use, _, _} = entry, recipe, index),
    do: {:error, use_entry(index, recipe, entry)}

  defp check_entry(ref, recipe, index) when is_binary(ref),
    do: check_entry({ref, []}, recipe, index)

  defp check_entry({ref, opts} = entry, recipe, index) when is_binary(ref) and is_list(opts) do
    with {:ok, _target} <- entry_target(index, entry, recipe), do: :ok
  end

  defp check_entry(_entry, _recipe, _index), do: :ok

  # What a string entry of `recipe` names: {:include, id, flag} or
  # {:step, found, via}. An old-syntax address is reported as such.
  defp entry_target(index, {string, opts}, recipe) do
    result =
      case Ref.parse(string) do
        {:ok, %Ref{kind: :recipe}} ->
          with {:ok, id} <- find_included(index, string, recipe),
               :ok <- include_options(string, opts, recipe),
               do: {:ok, {:include, id, opts[:if]}}

        _ ->
          with {:ok, found, via} <- lookup_step(index, string, opts, recipe),
               do: {:ok, {:step, found, via}}
      end

    old_syntax(result, index, recipe, string)
  end

  defp include_options(string, opts, recipe) do
    case Keyword.keys(opts) -- [:if] do
      [] -> :ok
      keys -> {:error, {:include_options, recipe.ref, string, Enum.uniq(keys)}}
    end
  end

  @old_syntax_errors [
    :invalid_ref,
    :unknown_cookbook,
    :missing_recipe,
    :missing_step,
    :kind_mismatch,
    :short_recipe
  ]

  # A failed lookup of an address that the old syntax read differently is
  # reported with its new spelling.
  defp old_syntax({:error, reason} = error, index, recipe, string)
       when elem(reason, 0) in @old_syntax_errors do
    case legacy_rewrite(index, recipe, :step, string) do
      {:ok, ^string} -> error
      {:ok, new} -> {:error, {:old_syntax, recipe.ref, string, [new]}}
      {:ambiguous, ids} -> {:error, {:old_syntax, recipe.ref, string, ids}}
      :error -> error
    end
  end

  defp old_syntax(result, _index, _recipe, _string), do: result

  defp use_entry(index, recipe, entry) do
    {written, opts} =
      case entry do
        {:use, written} -> {written, nil}
        {:use, written, opts} -> {written, opts}
      end

    rewrites =
      case is_binary(written) && legacy_rewrite(index, recipe, :use, written) do
        {:ok, new} -> [new]
        {:ambiguous, ids} -> ids
        _ -> []
      end

    {:use_entry, recipe.ref, entry, Enum.map(rewrites, &use_rewrite(&1, opts))}
  end

  # The text of a rewritten {:use, ...} entry.
  defp use_rewrite(new, nil), do: inspect(new)

  defp use_rewrite(new, opts),
    do: "{" <> inspect(new) <> ", " <> String.slice(Macro.to_string(opts), 1..-2//1) <> "}"

  # -- old syntax ---------------------------------------------------------

  @doc false
  # The new spelling of an address written in the old syntax, read with
  # Composer.Ref.Legacy as it resolved before addressing schemes, in a
  # recipe of `context`'s cookbook: `:step` for a string entry (or a step's
  # requires), `:use` for the target of a {:use, ...} include. Returns
  # {:ok, address}, {:ambiguous, ids} or :error. Unqualified references
  # resolve against the cookbooks in `index`. Used by the old-syntax
  # errors and mix composer.cookbook.lint --fix; it goes away with
  # Composer.Ref.Legacy.
  def legacy_rewrite(cookbooks, context, kind, string) do
    index = index(cookbooks)
    own = context(context).cookbook

    case Ref.Legacy.parse(string) do
      {:ok, %Ref.Legacy{cookbook: "hex"}} ->
        if kind == :step, do: {:ok, string}, else: :error

      {:ok, %Ref.Legacy{cookbook: nil, path: path}} ->
        legacy_unqualified(index, own, kind, path)

      {:ok, %Ref.Legacy{cookbook: cookbook, path: path}} ->
        {:ok, Ref.id(if(kind == :use, do: :recipe, else: :step), cookbook, path)}

      {:error, _} ->
        :error
    end
  end

  defp legacy_unqualified(index, own, :use, path) do
    cond do
      not String.contains?(path, "/") ->
        {:ok, "./" <> path}

      own && path in Map.get(index.recipes, own, []) ->
        {:ok, "/" <> path}

      true ->
        case for({name, ids} <- index.recipes, path in ids, do: Ref.id(:recipe, name, path)) do
          [id] -> {:ok, id}
          [] -> :error
          ids -> {:ambiguous, Enum.sort(ids)}
        end
    end
  end

  defp legacy_unqualified(index, own, :step, path) do
    if own && index.steps[own][path] do
      {:ok, ":" <> String.replace(path, "/", ":")}
    else
      case for({_name, steps} <- index.steps, meta = steps[path], do: meta.ref) do
        [ref] ->
          {:ok, ref}

        [] ->
          if String.contains?(path, "/") or step_suggestions(index, path) != [],
            do: :error,
            else: {:ok, "hex:" <> path}

        refs ->
          {:ambiguous, Enum.sort(refs)}
      end
    end
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

  # -- step addresses -----------------------------------------------------

  defp find_step(index, string, context, origin) do
    with {:ok, ref} <- Ref.parse(string) do
      case ref do
        %Ref{cookbook: "hex", segments: [package], source: source} ->
          {:ok, {:install, package, source}}

        %Ref{scope: :search, segments: [word]} ->
          search_step(index, string, word, context, origin)

        %Ref{kind: :recipe} ->
          {:error, {:kind_mismatch, :step, string, origin, step_twin(index, ref, context)}}

        %Ref{} ->
          with {:ok, cookbook} <- scope_cookbook(index, ref, string, context, origin) do
            path = Ref.path(ref)

            cond do
              meta = index.steps[cookbook][path] ->
                {:ok, {:module, meta}}

              twin = recipe_twin(index, ref, context) ->
                {:error, {:kind_mismatch, :step, string, origin, twin}}

              true ->
                {:error, {:missing_step, string, origin, step_suggestions(index, path)}}
            end
          end
      end
    end
  end

  # A bare word: searched on the command line, an error in source.
  defp search_step(index, string, word, %{cli?: true}, origin) do
    case search(index, word) do
      [] ->
        {:error,
         {:no_match, :step, string, step_suggestions(index, word), cookbook?(index, word)}}

      [id] ->
        case Ref.parse!(id) do
          %Ref{kind: :step} = ref ->
            {:ok, {:module, index.steps[ref.cookbook][Ref.path(ref)]}}

          _recipe ->
            {:error, {:kind_mismatch, :step, string, origin, id}}
        end

      ids ->
        {:error, {:ambiguous, :address, string, origin, ids}}
    end
  end

  defp search_step(index, string, word, context, origin) do
    case bare_candidates(index, word, context) do
      [] ->
        case step_suggestions(index, word) do
          [] -> {:error, {:bare_word, string, origin, ["hex:" <> word], []}}
          close -> {:error, {:bare_word, string, origin, [], close}}
        end

      candidates ->
        {:error, {:bare_word, string, origin, candidates, []}}
    end
  end

  # What a bare word in source could have meant: its old meaning first,
  # then every step or recipe it matches. When nothing does, it is the Hex
  # package of that name, unless it is close to a step name (a typo).
  defp bare_candidates(index, word, context) do
    old =
      case context.cookbook && legacy_rewrite(index, context, :step, word) do
        {:ok, "hex:" <> _} -> []
        {:ok, new} -> [new]
        {:ambiguous, ids} -> ids
        _ -> []
      end

    Enum.uniq(old ++ search(index, word))
  end

  defp cookbook?(index, word), do: Map.has_key?(index.by_name, word)

  # The cookbook a qualified or root address is in.
  defp scope_cookbook(index, %Ref{scope: :qualified, cookbook: name}, string, _context, origin) do
    if Map.has_key?(index.by_name, name),
      do: {:ok, name},
      else: {:error, {:unknown_cookbook, name, string, origin, Map.keys(index.by_name)}}
  end

  defp scope_cookbook(_index, %Ref{scope: :root}, string, %{cookbook: nil}, origin),
    do: {:error, {:not_a_cookbook, string, origin}}

  defp scope_cookbook(_index, %Ref{scope: scope}, _string, %{cookbook: own}, _origin)
       when scope in [:root, :relative],
       do: {:ok, own}

  # The recipe with the same cookbook and segments as step address `ref`,
  # or the reverse, when there is one.
  defp recipe_twin(index, ref, context) do
    with cookbook when is_binary(cookbook) <- twin_cookbook(ref, context),
         path = Ref.path(ref),
         true <- path in Map.get(index.recipes, cookbook, []) do
      Ref.id(:recipe, cookbook, path)
    else
      _ -> nil
    end
  end

  defp step_twin(index, ref, context) do
    with cookbook when is_binary(cookbook) <- twin_cookbook(ref, context),
         %{ref: id} <- index.steps[cookbook][Ref.path(ref)] do
      id
    else
      _ -> nil
    end
  end

  defp twin_cookbook(%Ref{scope: :qualified, cookbook: cookbook}, _context), do: cookbook
  defp twin_cookbook(%Ref{scope: :root}, %{cookbook: cookbook}), do: cookbook
  defp twin_cookbook(_ref, _context), do: nil

  # Close names, so a typo is reported with what was meant.
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
  # pg_extensions -> pg/extensions, or the reverse. Ids are segments
  # joined with /.
  defp regrouped?(id, path) do
    String.ends_with?(id, "/" <> path) or String.ends_with?(path, "/" <> id) or
      String.replace(id, "/", "_") == String.replace(path, "/", "_")
  end

  # -- recipe addresses ---------------------------------------------------

  defp find_recipe(index, string, context, origin) do
    with {:ok, ref} <- Ref.parse(string) do
      case ref do
        %Ref{scope: :search, segments: [word]} ->
          search_recipe(index, string, word, context, origin)

        %Ref{kind: :step} ->
          {:error, {:kind_mismatch, :recipe, string, origin, recipe_twin(index, ref, context)}}

        %Ref{scope: :relative} when context.chapter == nil ->
          {:error, {:no_chapter, string, origin}}

        %Ref{} ->
          with {:ok, cookbook} <- scope_cookbook(index, ref, string, context, origin),
               {:ok, path} <- recipe_path(ref, string, context, origin) do
            cond do
              length(String.split(path, "/")) < 2 ->
                case step_twin(index, ref, context) do
                  nil -> {:error, {:short_recipe, string, origin}}
                  twin -> {:error, {:kind_mismatch, :recipe, string, origin, twin}}
                end

              path in Map.get(index.recipes, cookbook, []) ->
                {:ok, Ref.id(:recipe, cookbook, path)}

              twin = ref.scope != :relative && step_twin(index, ref, context) ->
                {:error, {:kind_mismatch, :recipe, string, origin, twin}}

              true ->
                {:error,
                 {:missing_recipe, string, origin, recipe_suggestions(index, cookbook, path)}}
            end
          end
      end
    end
  end

  defp recipe_path(%Ref{scope: :relative, up: up, segments: segments}, string, context, origin) do
    case relative(context.chapter, up, segments) do
      {:ok, path} -> {:ok, path}
      {:error, :above_root} -> {:error, {:above_root, string, origin, context.chapter}}
    end
  end

  defp recipe_path(ref, _string, _context, _origin), do: {:ok, Ref.path(ref)}

  defp search_recipe(index, string, word, %{cli?: true}, origin) do
    case search(index, word) do
      [] ->
        {:error,
         {:no_match, :recipe, string, recipe_suggestions(index, nil, word),
          cookbook?(index, word)}}

      [id] ->
        case Ref.parse!(id) do
          %Ref{kind: :recipe} -> {:ok, id}
          _step -> {:error, {:kind_mismatch, :recipe, string, origin, id}}
        end

      ids ->
        {:error, {:ambiguous, :address, string, origin, ids}}
    end
  end

  defp search_recipe(index, string, word, _context, origin),
    do: {:error, {:bare_word, string, origin, search(index, word), []}}

  # Close recipes, the ones in `cookbook` first; every recipe when none is.
  defp recipe_suggestions(index, cookbook, path) do
    all =
      for {name, ids} <- index.recipes, id <- ids do
        {Ref.id(:recipe, name, id), if(name == cookbook, do: id, else: name <> "/" <> id)}
      end

    case ranked(all, path) do
      [] -> all |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      close -> close
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
    %Ref{cookbook: name, segments: segments} = ref = Ref.parse!(id)
    cookbook = Map.fetch!(state.index.by_name, name)

    case Cookbook.recipe_path(cookbook, Ref.path(ref)) do
      nil ->
        {:error, {:missing_recipe, id, nil, []}}

      file ->
        with {:ok, loaded, state} <- load_chapter(file, name, state),
             {:ok, recipe} <- Recipe.Chapter.pick(loaded, file, name, List.last(segments)) do
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

  # Replaces an aliased cookbook part of a qualified address written in
  # `recipe` with the real cookbook name. Returns the string to look up
  # and, for an aliased address, `{alias, target, written}` for errors and
  # display.
  defp expand(string, recipe) do
    with {:ok, %Ref{scope: :qualified, cookbook: name} = ref} <- Ref.parse(string),
         target when is_binary(target) <- Recipe.alias_target(recipe, name) do
      {Ref.to_string(%{ref | cookbook: target}), {name, target, string}}
    else
      _ -> {string, nil}
    end
  end

  # Rewrites a lookup error of an expanded address to show it as written.
  defp via_alias({:error, reason}, {name, target, written}) do
    case reason do
      {:unknown_cookbook, ^target, _ref, origin, known} ->
        {:error, {:unknown_alias_target, written, name, target, origin, known}}

      reason ->
        {:error, {:via_alias, written, name, target, reason}}
    end
  end

  defp via_alias(result, _via), do: result

  defp step({:use, _} = entry, recipe, _gates, state),
    do: {:error, use_entry(state.index, recipe, entry)}

  defp step({:use, _, _} = entry, recipe, _gates, state),
    do: {:error, use_entry(state.index, recipe, entry)}

  defp step({kind, task}, recipe, gates, state) when kind in [:task, :queue],
    do: step({kind, task, []}, recipe, gates, state)

  defp step({kind, task, argv}, recipe, gates, state) when kind in [:task, :queue],
    do: {:ok, emit(state, task_entry(kind, task, argv, nil, recipe.ref, gates))}

  defp step({kind, task, argv, opts}, recipe, gates, state) when kind in [:task, :queue],
    do: {:ok, emit(state, task_entry(kind, task, argv, opts[:if], recipe.ref, gates))}

  defp step(ref, recipe, gates, state) when is_binary(ref),
    do: step({ref, []}, recipe, gates, state)

  defp step({ref, opts} = entry, recipe, gates, state) when is_binary(ref) do
    flag = opts[:if]

    case Ref.parse(ref) do
      {:ok, %Ref{kind: :recipe}}
      when flag != nil and state.flags != :all ->
        if Keyword.get(state.flags, flag, false) == true,
          do: include(entry, recipe, gates, state),
          else: {:ok, state}

      {:ok, %Ref{kind: :recipe}} ->
        include(entry, recipe, gates, state)

      _ ->
        with {:ok, {:step, found, via}} <- entry_target(state.index, entry, recipe) do
          entry = leaf(found, recipe.ref, gates, flag, opts)
          {:ok, emit(state, %{entry | alias: via && elem(via, 0)})}
        end
    end
  end

  # Finds the step or package a `{ref, opts}` entry of `recipe` names,
  # with the recipe's aliases expanded.
  defp lookup_step(index, ref, opts, recipe) do
    {lookup, via} = expand(ref, recipe)
    package_keys = for {key, _} <- opts, key in Recipe.package_options(), do: key

    case via_alias(find_step(index, lookup, context(recipe), recipe.ref), via) do
      {:ok, {:module, meta}} when package_keys != [] ->
        {:error, {:dep_opts_on_step, ref, meta.ref, recipe.ref, package_keys}}

      {:ok, found} ->
        {:ok, found, via}

      error ->
        error
    end
  end

  defp include({_ref, opts} = entry, recipe, gates, state) do
    flag = opts[:if]

    with {:ok, {:include, id, _flag}} <- entry_target(state.index, entry, recipe) do
      if MapSet.member?(state.done, id) do
        {:ok, state}
      else
        state = if flag, do: %{state | gates: [flag | state.gates]}, else: state
        visit(id, gates ++ List.wrap(flag), state)
      end
    end
  end

  defp find_included(index, ref, recipe) do
    {lookup, via} = expand(ref, recipe)
    via_alias(find_recipe(index, lookup, context(recipe), recipe.ref), via)
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
            id = requirement_id(ref, entry.meta.cookbook),
            not Enum.any?(earlier, &(&1.ref == id)),
            do: {:requires_order, entry, ref}

      _ ->
        []
    end)
  end

  @doc """
  The canonical id a `requires:` string of a step in `cookbook` names: a
  qualified step address as is, a root one (`":cluster:libcluster"`) in
  `cookbook`, `"hex:pkg"` without its source. `nil` for anything else.
  """
  @spec requirement_id(String.t(), String.t()) :: String.t() | nil
  def requirement_id(required, cookbook) do
    case Ref.parse(required) do
      {:ok, %Ref{cookbook: "hex", segments: [package]}} ->
        "hex:" <> package

      {:ok, %Ref{kind: :step, scope: :qualified} = ref} ->
        Ref.id(:step, ref.cookbook, ref.segments)

      {:ok, %Ref{kind: :step, scope: :root} = ref} ->
        Ref.id(:step, cookbook, ref.segments)

      _ ->
        nil
    end
  end
end
