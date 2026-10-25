defmodule Composer.Lint do
  @moduledoc """
  Checks a cookbook for `mix composer.cookbook.lint`.

  Lint is a set of plain functions: it takes discovered cookbooks, prints
  nothing and never raises. Every problem is a `Composer.Lint.Diagnostic`,
  located where it is written (see `Composer.Error.anchor/1` and
  `Composer.Recipe.Locator`), in a stable order. Recipes are checked in two
  passes: each entry of each recipe on its own (so every bad reference is
  reported), then each recipe as a whole (for cycles and conflicting
  installs); a problem is reported once, in the recipe that has it.

  Errors, for a package cookbook (`run/3`):

    * every step has a summary, an `action` and a `stability`
    * every step has a test at `test/composer/<cookbook>/steps/<id>_test.exs`
    * every step address in `requires` resolves; one in the old syntax is
      `old_requires`, with its rewrite
    * the committed manifest holds the same data as a freshly built one
    * the chapter rules below
    * every recipe resolves (with every include followed); this also
      reports a cookbook alias named like an installed cookbook
    * a leftover cookbook-level `templates/` directory
    * a file under `steps/` that no step owns: it is not in a step's
      template directory (`steps/_<id>/`, beside `steps/<id>.ex`)
    * a step's templates in an unprefixed `steps/<id>/` directory
    * a `.ex` file under `steps/` that is not a compiled step module
    * a `template/1` path that does not exist

  Files under `steps/` that git ignores are skipped.

  Chapter rules:

    * a chapter file or a directory under `recipes/` with an invalid name
      (`invalid_chapter_path`); chapters may be nested in directories
    * a chapter file that holds no recipes (`empty_chapter`)
    * a chapter file that is not a keyword list of recipes
    * a duplicate recipe name within a chapter
    * a recipe missing `shortdoc` or `steps`, with an unknown key, or with
      a value of the wrong type; a `shortdoc` on more than one line
    * an address the resolver rejects, among them (with `--fix` rewriting
      those that have one rewrite): `old_syntax` (`"cb_std:setup/credo"`),
      `use_entry` (`{:use, "base"}`), `bare_word` (`"oban"`),
      `kind_mismatch` (`"cb_std/echo"` for the step `cb_std:echo`),
      `relative_step` (`".:dns"`), `above_root` (`"../../../core"`),
      `include_options` (`{"./base", argv: [...]}`)
    * an `if:` flag that the recipe does not declare in its own `flags`
    * a declared flag with a reserved name (`Composer.Recipe.reserved_flags/0`)
    * an invalid, reserved (`cb_std`, `hex`, `local`), duplicate or
      atom-valued cookbook alias, or one whose target is not a package
      cookbook name

  Warnings:

    * an address in the old syntax shown in a recipe's `shortdoc:` or
      `doc:` (`old_doc_address`), which `--fix` does not rewrite
    * a cookbook alias that none of the recipe's own references use
    * an alias that names different cookbooks in two recipes of one chapter
    * a step and a recipe share an id, which is allowed but confusing
    * a file in a step's template directory that its `template/1` calls
      never refer to (skipped for a step whose `template/1` path is
      computed at run time)
    * a path dependency in a project that has a `package:` section (given
      as the `:project` option): a cookbook installed from git or Hex
      can't resolve it

  A file belongs to the step named by the first directory on its path that
  starts with `_`: `steps/ash/_postgres/x/y` belongs to `ash/postgres`.
  Step path segments never start with `_`, so a `steps/<id>/` directory
  only ever holds child steps.
  """

  alias Composer.{Error, Manifest, Ref, Cookbook, Resolver}
  alias Composer.Lint.{Diagnostic, Locate}
  alias Composer.Recipe.Chapter

  @type result :: %{diagnostics: [Diagnostic.t()]}

  # A problem before it is located: its severity, its reason, and the
  # recipe being checked when it was found (or nil).
  @typep problem :: {:error | :warning, term(), String.t() | nil}

  @doc """
  Lints `cookbook`, resolving references against `cookbooks`. `root` is
  the project root, where step tests are looked for.

  ## Options

    * `:project` - the cookbook's Mix project config
      (`Mix.Project.config/0`), for the path dependency check; skipped
      when absent
  """
  @spec run(Cookbook.t(), [Cookbook.t()], Path.t(), keyword()) :: result()
  def run(%Cookbook{} = cookbook, cookbooks, root, opts \\ []) do
    steps = Cookbook.steps(cookbook)
    index = Resolver.index(cookbooks)
    recipes = recipes(cookbook, index)
    recipe_ids = Cookbook.recipes(cookbook)

    problems =
      errors(Enum.flat_map(steps, &metadata/1)) ++
        errors(Enum.flat_map(steps, &test_file(&1, cookbook, root))) ++
        errors(Enum.flat_map(steps, &requires(&1, cookbooks))) ++
        errors(manifest(cookbook)) ++
        templates(cookbook, steps) ++
        recipes.problems ++
        deep(cookbook, cookbooks, recipes.loaded, recipes) ++
        path_deps(opts[:project], root) ++
        for %{id: id} <- steps,
            id in recipe_ids,
            do: {:warning, {:step_recipe_clash, Ref.id(:recipe, cookbook.name, id)}, nil}

    %{diagnostics: build(problems, Locate.new(cookbooks, recipes.loaded, root: root))}
  end

  @doc """
  Lints chapter files: for each of `paths`, the diagnostics located
  in it.

  Every cookbook's chapters are checked, since includes cross files, but
  only the recipes in `paths` are resolved as a whole. Each
  `{:use, ...}` in those files whose target, or anything it includes,
  has problems gets one `:include_problems` diagnostic, with the problems
  as related locations.

  Files are matched by path, following symbolic links; results are keyed,
  and their `file`s given, as in `paths`.

  ## Options

    * `:root` - the project root
  """
  @spec files([Cookbook.t()], [Path.t()], keyword()) :: %{Path.t() => [Diagnostic.t()]}
  def files(cookbooks, paths, opts \\ []) do
    index = Resolver.index(cookbooks)
    checked = for book <- cookbooks, book.kind != :virtual, do: {book, recipes(book, index)}
    loaded = Enum.flat_map(checked, fn {_book, recipes} -> recipes.loaded end)
    in_paths = fn recipe -> Enum.any?(paths, &same_file?(recipe.path, &1)) end

    deep =
      Enum.flat_map(checked, fn {book, recipes} ->
        deep(book, cookbooks, Enum.filter(recipes.loaded, in_paths), recipes)
      end)

    problems = Enum.flat_map(checked, fn {_book, recipes} -> recipes.problems end) ++ deep
    locate = Locate.new(cookbooks, loaded, root: opts[:root])
    {located, locate} = locate(problems, locate)
    graph = include_graph(index, loaded)

    Map.new(paths, fn path ->
      own = for {d, _recipe} <- located, d.file && same_file?(d.file, path), do: %{d | file: path}

      summaries =
        for recipe <- loaded, same_file?(recipe.path, path) do
          summaries(recipe, index, graph, located, locate)
        end

      {path, finish(own ++ Enum.map(List.flatten(summaries), &%{&1 | file: path}))}
    end)
  end

  @doc """
  Returns the recipes that include recipe `ref` (or any of a list of
  refs), directly or through other includes, as
  `%{ref: ref, path: chapter_file}`, sorted by ref. The given refs are left
  out.
  """
  @spec dependents([Cookbook.t()], String.t() | [String.t()]) ::
          [%{ref: String.t(), path: Path.t()}]
  def dependents(cookbooks, ref) do
    refs = List.wrap(ref)
    index = Resolver.index(cookbooks)

    loaded =
      for book <- cookbooks,
          book.kind != :virtual,
          recipe <- elem(Cookbook.load_recipes(book), 0),
          do: recipe

    reverse =
      for {from, targets} <- include_graph(index, loaded),
          to <- targets,
          reduce: %{},
          do: (acc -> Map.update(acc, to, [from], &[from | &1]))

    by_ref = Map.new(loaded, &{&1.ref, &1})

    reverse
    |> closure(refs)
    |> Kernel.--(refs)
    |> Enum.sort()
    |> Enum.map(&%{ref: &1, path: by_ref[&1].path})
  end

  @doc """
  Finds the cookbook a chapter file belongs to: the one in
  `cookbooks` whose `recipes/` holds it.
  """
  @spec owner([Cookbook.t()], Path.t()) :: {:ok, Cookbook.t()} | {:error, term()}
  def owner(cookbooks, path) do
    path = Path.expand(path)

    cond do
      not File.regular?(path) ->
        {:error, {:lint_file_missing, path}}

      book =
          Enum.find(cookbooks, &(&1.kind == :code and in_recipes?(path, Cookbook.source_dir(&1)))) ->
        {:ok, book}

      true ->
        {:error, {:lint_file_unknown, path}}
    end
  end

  defp in_recipes?(_path, nil), do: false

  defp in_recipes?(path, dir) do
    recipes = Path.join(dir, "recipes")

    path
    |> Path.dirname()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take_while(&(&1 != Path.dirname(&1)))
    |> Enum.any?(&same_file?(&1, recipes))
  end

  # -- building diagnostics -------------------------------------------------

  defp errors(reasons), do: for(reason <- reasons, do: {:error, reason, nil})

  # A published cookbook's path deps resolve only on its author's machine.
  defp path_deps(nil, _root), do: []

  defp path_deps(project, root) do
    if project[:package] do
      mix_exs = Path.join(root, "mix.exs")

      lines =
        case File.read(mix_exs) do
          {:ok, text} -> String.split(text, "\n")
          {:error, _} -> []
        end

      for dep <- List.wrap(project[:deps]),
          app = path_dep(dep),
          do: {:warning, {:path_dep_in_package, app, {mix_exs, dep_line(lines, app)}}, nil}
    else
      []
    end
  end

  # The line declaring the dep, if it is written as `{:app, ...`.
  defp dep_line(lines, app) do
    needle = "{#{inspect(app)},"
    if index = Enum.find_index(lines, &String.contains?(&1, needle)), do: index + 1
  end

  defp path_dep({app, opts}) when is_list(opts), do: if(opts[:path], do: app)
  defp path_dep({app, _requirement, opts}) when is_list(opts), do: if(opts[:path], do: app)
  defp path_dep(_dep), do: nil

  @spec build([problem()], Locate.t()) :: [Diagnostic.t()]
  defp build(problems, locate) do
    {located, _locate} = locate(problems, locate)
    located |> dedupe() |> Enum.map(&elem(&1, 0)) |> sort()
  end

  # Each problem as a located diagnostic, with the recipe it is about.
  defp locate(problems, locate) do
    {located, locate} =
      Enum.map_reduce(problems, locate, fn {severity, reason, context}, locate ->
        anchor = Error.anchor(reason)
        {{file, range, related}, locate} = Locate.place(locate, anchor, context)

        diagnostic =
          severity
          |> Diagnostic.new(reason)
          |> Diagnostic.locate(file, range, related)
          |> with_fix(reason, range)

        {{diagnostic, anchor_recipe(anchor, context, locate)}, locate}
      end)

    {dedupe(located), locate}
  end

  # The one rewrite of a problem, when it has one, at the range it was
  # placed at; `expect` is what the range must hold for the fix to apply.
  defp with_fix(%Diagnostic{file: nil} = diagnostic, _reason, _range), do: diagnostic
  defp with_fix(diagnostic, _reason, nil), do: diagnostic

  defp with_fix(diagnostic, reason, range) do
    case fix(reason) do
      nil -> diagnostic
      {expect, text} -> %{diagnostic | fix: %{range: range, expect: expect, text: text}}
    end
  end

  defp fix({:old_syntax, _origin, written, [new]}), do: {written, inspect(new)}
  defp fix({:bare_word, written, _origin, [one], _close}), do: {written, inspect(one)}

  defp fix({:kind_mismatch, _kind, written, _origin, twin}) when is_binary(twin),
    do: {written, inspect(twin)}

  defp fix({:use_entry, _ref, entry, [text]}), do: {entry, text}
  defp fix({:old_requires, _step, _module, written, [new]}), do: {written, inspect(new)}
  defp fix(_reason), do: nil

  # One diagnostic per kind of problem and place. Two recipes sharing a
  # binding can have the same problem at one place, so the recipe counts.
  defp dedupe(located) do
    Enum.uniq_by(located, fn
      {%{file: nil} = d, _recipe} -> {d.code, d.message}
      {d, recipe} -> {d.code, d.file, d.line, d.column, recipe}
    end)
  end

  defp finish(diagnostics) do
    diagnostics
    |> Enum.uniq_by(&{&1.code, &1.file, &1.line, &1.column, &1.message})
    |> sort()
  end

  defp sort(diagnostics) do
    Enum.sort_by(diagnostics, fn d ->
      {d.file || "", d.line || 0, d.column || 0, d.severity, d.code, d.message}
    end)
  end

  # The recipe a problem is about, if any.
  defp anchor_recipe({:ref, origin, _written}, context, _locate), do: origin || context

  defp anchor_recipe({kind, ref, _}, _context, _locate)
       when kind in [:entry, :recipe_key, :alias],
       do: ref

  defp anchor_recipe({:recipe, ref}, _context, _locate), do: ref

  defp anchor_recipe({:recipe_named, cookbook, name}, _context, locate),
    do: Locate.recipe_named(locate, cookbook, name)

  defp anchor_recipe(_anchor, _context, _locate), do: nil

  # -- include summaries ------------------------------------------------------

  defp include_graph(index, recipes) do
    Map.new(recipes, fn recipe ->
      {recipe.ref, for({_written, {:ok, id}} <- Resolver.included(index, recipe), do: id)}
    end)
  end

  # Every id reachable from `ids` in `graph`, including `ids`.
  defp closure(graph, ids), do: closure(graph, ids, MapSet.new()) |> MapSet.to_list()

  defp closure(_graph, [], seen), do: seen

  defp closure(graph, [id | rest], seen) do
    if MapSet.member?(seen, id),
      do: closure(graph, rest, seen),
      else: closure(graph, Map.get(graph, id, []) ++ rest, MapSet.put(seen, id))
  end

  # One diagnostic at each {:use, ...} of `recipe` whose target, or what
  # it includes, has problems: those in the included recipes, and those
  # about no recipe in particular in their chapter files.
  defp summaries(recipe, index, graph, located, locate) do
    for {written, {:ok, target}} <- Resolver.included(index, recipe),
        reached = closure(graph, [target]),
        files = Enum.flat_map(reached, &List.wrap(Locate.recipe_path(locate, &1))),
        problems =
          for(
            {d, about} <- located,
            if(about,
              do: about in reached,
              else: d.file != nil and Enum.any?(files, &same_file?(&1, d.file))
            ),
            do: d
          ),
        problems != [] do
      severity = if Enum.any?(problems, &Diagnostic.error?/1), do: :error, else: :warning
      reason = {:include_problems, recipe.ref, written, target, length(problems)}
      {{file, range, _}, _locate} = Locate.place(locate, Error.anchor(reason), recipe.ref)

      related =
        for d <- problems,
            do: %{file: d.file, range: Diagnostic.range(d), message: "#{d.code}: #{d.message}"}

      severity |> Diagnostic.new(reason) |> Diagnostic.locate(file, range, related)
    end
  end

  defp same_file?(a, b) do
    a = Path.expand(a)
    b = Path.expand(b)
    a == b or real_path(a) == real_path(b)
  end

  # `path` with every symbolic link on it resolved.
  defp real_path(path, depth \\ 0) do
    [root | segments] = Path.split(Path.expand(path))

    Enum.reduce(segments, root, fn segment, acc ->
      path = Path.join(acc, segment)

      case File.read_link(path) do
        {:ok, target} when depth < 32 -> real_path(Path.expand(target, acc), depth + 1)
        _ -> path
      end
    end)
  end

  # -- chapters ----------------------------------------------------------

  # The chapter checks of `cookbook` and the shallow pass: each entry of each
  # loaded recipe checked on its own, so every bad reference is reported.
  defp recipes(cookbook, index) do
    {files, dirs} = Cookbook.recipe_entries(cookbook)

    results =
      for {chapter, path} <- files do
        if Chapter.valid_path?(chapter),
          do: chapter(path, cookbook.name),
          else: %{problems: [{:error, {:invalid_chapter_path, path}, nil}], loaded: []}
      end

    # A bad directory is reported once, not again for each file below it.
    bad_dirs =
      for {relative, path} <- dirs,
          not Chapter.valid_name?(Path.basename(relative)),
          Path.dirname(relative) == "." or Chapter.valid_path?(Path.dirname(relative)),
          do: {:invalid_chapter_path, path}

    results =
      Enum.reject(results, fn
        %{problems: [{:error, {:invalid_chapter_path, path}, nil}]} ->
          Enum.any?(bad_dirs, fn {_, dir} -> String.starts_with?(path, dir <> "/") end)

        _ ->
          false
      end)

    loaded = Enum.flat_map(results, & &1.loaded)

    shallow =
      for recipe <- loaded,
          reason <- Resolver.check_entries(index, recipe),
          do: {:error, reason, recipe.ref}

    %{
      problems:
        errors(legacy_dir(cookbook)) ++
          errors(bad_dirs) ++
          Enum.flat_map(results, & &1.problems) ++ shallow,
      loaded: loaded,
      shallow: MapSet.new(shallow, &elem(&1, 1)),
      linted: MapSet.new(loaded, & &1.ref)
    }
  end

  # Chapters used to live under profiles/, which is no longer read.
  defp legacy_dir(%Cookbook{kind: :code} = cookbook) do
    with dir when is_binary(dir) <- Cookbook.source_dir(cookbook),
         path = Path.join(dir, "profiles"),
         true <- File.dir?(path) do
      [{:legacy_recipes_dir, path}]
    else
      _ -> []
    end
  end

  defp legacy_dir(_cookbook), do: []

  # Evaluated first, so the shape error shows what the file holds; the
  # syntax-tree check (names must be literal) only runs on a valid chapter.
  defp chapter(path, cookbook) do
    case Chapter.eval(path, cookbook) do
      {:ok, term} ->
        {loaded, errors} = Chapter.check_tagged(term, path, cookbook)

        errors =
          case errors == [] && Chapter.names(path) do
            {:error, reason} -> [{reason, nil}]
            _ -> errors
          end

        multiline =
          for recipe <- loaded,
              String.contains?(String.trim(recipe.shortdoc), "\n"),
              do: {:error, {:multiline_shortdoc, recipe.ref}, recipe.ref}

        empty = if term == [], do: [{:error, {:empty_chapter, path}, nil}], else: []
        docs = Enum.flat_map(loaded, &old_doc_addresses/1)

        # A chapter with problems is not resolved, to avoid repeating them.
        loaded = if errors == [], do: loaded, else: []

        %{
          problems:
            for({reason, ref} <- errors, do: {:error, reason, ref}) ++
              multiline ++
              empty ++ docs ++ unused_aliases(loaded) ++ inconsistent_aliases(path, loaded),
          loaded: loaded
        }

      {:error, reason} ->
        %{problems: [{:error, reason, nil}], loaded: []}
    end
  end

  # Addresses in the old syntax shown in a recipe's shortdoc: or doc:,
  # which --fix leaves alone: `cookbook:path/with/slashes` and {:use, ...}.
  @old_address ~r/(?<![\w@.\/:-])(?!(?:hex|path|github|git|https?):)[a-z][a-z0-9_]*:[a-z0-9_]+(?:\/[a-z0-9_]+)+|\{:use,/

  defp old_doc_addresses(recipe) do
    for {key, text} <- [shortdoc: recipe.shortdoc, doc: recipe.doc],
        is_binary(text),
        found = @old_address |> Regex.scan(text) |> List.flatten() |> Enum.uniq(),
        found != [] do
      {:warning, {:old_doc_address, recipe.ref, key, found}, recipe.ref}
    end
  end

  defp unused_aliases(recipes) do
    for recipe <- recipes,
        used = Composer.Recipe.cookbooks_referenced(recipe.steps),
        {name, target} <- recipe.aliases,
        Atom.to_string(name) not in used do
      {:warning, {:unused_alias, recipe.ref, name, target}, recipe.ref}
    end
  end

  # Legal, since aliases are per recipe, but the same short name meaning
  # two cookbooks in one file is easy to misread.
  defp inconsistent_aliases(path, recipes) do
    recipes
    |> Enum.flat_map(fn recipe ->
      Enum.map(recipe.aliases, &{elem(&1, 0), elem(&1, 1), recipe.ref})
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.flat_map(fn {name, uses} ->
      case Enum.uniq_by(uses, &elem(&1, 1)) do
        [_] ->
          []

        distinct ->
          uses = for {_name, target, ref} <- distinct, do: {target, ref}
          [{:warning, {:inconsistent_alias, path, name, uses}, nil}]
      end
    end)
  end

  # Resolves each recipe as a whole, for what only the tree shows (cycles,
  # conflicting installs). A problem the shallow pass already reported, or
  # one written in a recipe it checked, is left to it.
  defp deep(_cookbook, cookbooks, recipes, shallow) do
    for recipe <- recipes,
        {:error, reason} <- [
          Resolver.resolve_recipe(cookbooks, recipe.ref, flags: :all)
        ],
        not MapSet.member?(shallow.shallow, reason),
        not shallow_origin?(Error.anchor(reason), shallow.linted),
        do: {:error, reason, recipe.ref}
  end

  defp shallow_origin?({:ref, origin, _written}, linted) when is_binary(origin),
    do: MapSet.member?(linted, origin)

  defp shallow_origin?(_anchor, _linted), do: false

  # -- templates ----------------------------------------------------------

  defp templates(cookbook, steps) do
    case Cookbook.source_dir(cookbook) do
      nil -> []
      dir -> templates(cookbook, steps, dir)
    end
  end

  defp templates(cookbook, steps, dir) do
    root = dir |> Path.join("steps") |> Path.expand()
    legacy = Path.join(dir, "templates")
    {ex_files, others} = Cookbook.step_entries(cookbook)
    ids = MapSet.new(steps, & &1.id)
    # mix composer.gen.cookbook keeps an empty steps/ in git with a .gitkeep.
    others = others -- [".gitkeep", ".keep"]
    owners = Map.new(others, &{&1, template_owner(&1, ex_files)})

    orphans =
      for {_file, {:orphan, dir, step}} <- owners,
          uniq: true,
          do: {:orphaned_templates, Path.expand(dir, root), step && Path.join(root, step)}

    unprefixed =
      for {_file, {:unprefixed, id}} <- owners,
          uniq: true,
          do:
            {:unprefixed_templates, Path.join(root, id),
             Path.join(root, Composer.Step.template_dir(id))}

    not_steps =
      for file <- ex_files,
          not MapSet.member?(ids, Path.rootname(file, ".ex")),
          do: {:not_a_step, Path.join(root, file)}

    missing =
      for meta <- steps,
          path when is_binary(path) <- step_templates(meta),
          file = Path.join([root, Composer.Step.template_dir(meta.id), path]),
          not File.exists?(file),
          do: {:missing_template, meta.ref, path, file}

    errors =
      if(File.dir?(legacy), do: [{:legacy_templates_dir, legacy}], else: []) ++
        Enum.sort(orphans) ++ Enum.sort(unprefixed) ++ not_steps ++ missing

    errors(errors) ++ unused(steps, owners, root)
  end

  # The step owning a file under steps/: the first directory on its path
  # that starts with `_`, `p/_name`, is the template directory of `p/name`.
  # A file with no such directory is in an unprefixed template directory
  # when a directory `d` above it has a `d.ex`, and owned by nothing
  # otherwise.
  defp template_owner(file, ex_files) do
    dir = Path.dirname(file)

    case Enum.split_while(Path.split(dir), &(not String.starts_with?(&1, "_"))) do
      {parents, ["_" <> name = template_dir | _]} ->
        id = Path.join(parents ++ [name])
        step = id <> ".ex"

        if step in ex_files,
          do: {:step, id},
          else: {:orphan, Path.join(parents ++ [template_dir]), step}

      {_, []} ->
        case unprefixed(dir, ex_files) do
          nil -> {:orphan, dir, nil}
          id -> {:unprefixed, id}
        end
    end
  end

  # The nearest directory `d` at or above `dir` with a `d.ex`.
  defp unprefixed(".", _ex_files), do: nil

  defp unprefixed(dir, ex_files) do
    if (dir <> ".ex") in ex_files,
      do: dir,
      else: unprefixed(Path.dirname(dir), ex_files)
  end

  defp unused(steps, owners, root) do
    for meta <- steps,
        refs = step_templates(meta),
        :dynamic not in refs,
        refs = Enum.map(refs, &String.trim_trailing(&1, "/")),
        {file, {:step, id}} <- Enum.sort(owners),
        id == meta.id,
        relative = Path.relative_to(file, Composer.Step.template_dir(id)),
        not Enum.any?(refs, &(relative == &1 or String.starts_with?(relative, &1 <> "/"))) do
      {:warning, {:unused_template, meta.ref, meta.module, Path.join(root, file)}, nil}
    end
  end

  # A step compiled before template/1 recorded its paths is not checked.
  defp step_templates(%{module: module}) do
    if function_exported?(module, :__composer_templates__, 0),
      do: module.__composer_templates__(),
      else: [:dynamic]
  end

  # -- steps --------------------------------------------------------------

  defp metadata(meta) do
    for {key, value} <- [summary: meta.summary, action: meta.action, stability: meta.stability],
        value == nil do
      {:step_missing_meta, meta.ref, meta.module, key}
    end
  end

  defp test_file(meta, cookbook, root) do
    path = Path.join(["test", "composer", cookbook.name, "steps", meta.id <> "_test.exs"])

    if File.regular?(Path.join(root, path)),
      do: [],
      else: [{:missing_step_test, meta.ref, meta.module, path}]
  end

  # Requirements are cookbook source: resolved against the step's own
  # cookbook, with no search. One in the old syntax compiles with a
  # warning; it is reported here with its rewrite.
  defp requires(meta, cookbooks) do
    for ref when is_binary(ref) <- meta.requires,
        problem = requirement_problem(meta, ref, cookbooks),
        do: problem
  end

  defp requirement_problem(meta, ref, cookbooks) do
    if Composer.Facets.requirement?(ref) do
      case Resolver.find_step(cookbooks, ref, meta.cookbook) do
        {:ok, _found} -> nil
        {:error, reason} -> {:requires_unresolved, meta.ref, meta.module, ref, reason}
      end
    else
      rewrites =
        case Resolver.legacy_rewrite(cookbooks, meta.cookbook, :step, ref) do
          {:ok, new} -> [new]
          {:ambiguous, ids} -> ids
          :error -> []
        end

      {:old_requires, meta.ref, meta.module, ref, rewrites}
    end
  end

  # Compares data, not text: the manifest is an .exs file under lib/, so
  # the project's formatter (and plugins such as Quokka) may restyle it.
  defp manifest(cookbook) do
    path = Manifest.path(cookbook)

    cond do
      path == nil ->
        []

      not File.regular?(path) ->
        [{:manifest_missing, path}]

      Manifest.read(cookbook) != {:ok, Manifest.build(cookbook)} ->
        [{:manifest_stale, path}]

      true ->
        []
    end
  end
end
