defmodule Composer.Error do
  @moduledoc """
  Formats the `{:error, reason}` values returned by composer's modules, and
  the warnings returned by `Composer.Resolver.warnings/1`.

  Library functions return errors as data; Mix tasks pass the reason to
  `message/1` and raise with `Mix.raise/1`. Every message says what is wrong
  and how to fix it.
  """

  @group_example """
  A group file looks like:

      [
        base: [
          shortdoc: "One line, shown by mix composer.recipe.list",
          steps: ["core:setup/credo", "hex:oban"]
        ],
        app: [
          shortdoc: "Builds on base",
          flags: [gigalixir: "Deploy to Gigalixir"],
          steps: [{:use, "base"}, {"core:cluster/gigalixir", if: :gigalixir}]
        ]
      ]

  A single-recipe file (a plain list of steps) is no longer supported: \
  move its steps under a name in a group file.
  """

  @doc "Returns a human-readable message for an error reason."
  @spec message(term()) :: String.t()
  def message({:invalid_ref, ref, why}) do
    "Invalid reference #{inspect(ref)}: #{why}.\n\nA reference is \"cookbook:path\" or \"path\", e.g. \"core:setup/credo\" or \"ash/postgres\"."
  end

  def message({:recipe_eval, ref, path, exception, _line}) do
    "Could not evaluate recipe group #{ref} (#{path}):\n\n" <> Exception.message(exception)
  end

  def message({:group_read, path, reason}) do
    "Could not read recipe group #{path}: #{:file.format_error(reason)}"
  end

  def message({:group_parse, path, description, _line}) do
    "Recipe group #{path} does not parse: #{description}"
  end

  def message({:group_shape, path, :not_literal}) do
    """
    Recipe group #{path} must end in a literal keyword list of recipes, \
    so its recipe names can be read without evaluating it.

    #{@group_example}
    """
  end

  def message({:group_shape, path, term}) do
    """
    Recipe group #{path} must evaluate to a keyword list of recipes, got:

        #{inspect(term, pretty: true, limit: 10)}

    #{@group_example}
    """
  end

  def message({:invalid_group_name, path}) do
    """
    Recipe group #{path} has an invalid name. A group name is a lowercase \
    [a-z0-9_] segment; rename the file (for example lv-base.exs to lv_base.exs).
    """
  end

  def message({:invalid_recipe_name, path, name}) do
    "Recipe #{inspect(name)} in #{path} has an invalid name. Recipe names are lowercase [a-z0-9_] segments."
  end

  def message({:recipe_shape, ref, term}) do
    """
    Recipe #{ref} must be a keyword list with at least shortdoc: and steps:, got:

        #{inspect(term, pretty: true, limit: 10)}
    """
  end

  def message({:recipe_missing_key, ref, key}) do
    "Recipe #{ref} has no #{key}:. Every recipe needs shortdoc: (one line) and steps: (a list)."
  end

  def message({:unknown_recipe_key, ref, key}) do
    "Recipe #{ref} has an unknown key #{inspect(key)}. The keys are shortdoc:, doc:, flags:, aliases: and steps:."
  end

  def message({:bad_recipe_value, ref, key, value}) do
    expected =
      case key do
        :shortdoc -> "a non-empty string"
        :doc -> "a string"
        :flags -> ~s(a keyword list of flag descriptions, e.g. [oban_pro: "Add Oban Pro"])
        :steps -> "a list of step entries"
        :aliases -> ~s(a keyword list of cookbook names, e.g. [lab: "composer_lab"])
      end

    "Recipe #{ref} has an invalid #{key}: #{inspect(value, limit: 10)}. Expected #{expected}."
  end

  def message({:invalid_alias, ref, name}) do
    "Recipe #{ref} declares an invalid alias #{inspect(name)}. An alias is a lowercase [a-z0-9_] name, e.g. lab:."
  end

  def message({:reserved_alias, ref, name}) do
    "Recipe #{ref} declares the alias #{name}:, but #{name} is a reserved cookbook name. Choose another alias."
  end

  def message({:duplicate_alias, ref, name}) do
    "Recipe #{ref} declares the alias #{name}: more than once. Keep one."
  end

  def message({:alias_atom_target, ref, name, target}) do
    """
    Recipe #{ref} aliases #{name} to the atom #{inspect(target)}. An alias \
    names a cookbook by string: aliases: [#{name}: #{inspect(Atom.to_string(target))}].
    """
  end

  def message({:invalid_alias_target, ref, name, target}) do
    """
    Recipe #{ref} aliases #{name} to #{inspect(target)}, which is not a \
    package cookbook name. An alias target is the name of an installed \
    package's cookbook (its OTP app, e.g. "composer_lab"); core, hex, \
    local and other reserved names cannot be aliased.
    """
  end

  def message({:alias_shadows_cookbook, ref, name}) do
    """
    Recipe #{ref} declares the alias #{name}:, but #{name} is an installed \
    cookbook. An alias may not hide a real cookbook; choose another alias.
    """
  end

  def message({:unknown_alias_target, written, name, target, origin, known}) do
    """
    #{where(origin)}#{written} (#{name} = #{target}): cookbook #{target} not found.

    Available cookbooks: #{Enum.join(Enum.sort(known), ", ")}

    If #{target} is a package that ships a composer cookbook, add it to your \
    dependencies, e.g. {:#{target}, "~> x.y", only: :dev}, and run mix deps.get.
    """
  end

  def message({:via_alias, written, name, target, reason}) do
    String.trim_trailing(message(reason)) <>
      "\n\n#{inspect(written)} uses the alias #{name} = #{target}."
  end

  def message({:multiline_shortdoc, ref}) do
    "Recipe #{ref} has a shortdoc on more than one line. Keep it to one line and put the rest in doc:."
  end

  def message({:duplicate_recipe, path, name}) do
    "Recipe group #{path} defines the recipe #{name} more than once. Recipe names in a group must be unique."
  end

  def message({:undeclared_flag, ref, flag}) do
    """
    Recipe #{ref} uses if: #{inspect(flag)}, but does not declare it. Add it \
    to the recipe's flags:, e.g. flags: [#{flag}: "What --#{dashed(flag)} does"].
    """
  end

  def message({:unknown_flag, switch, root, declared}) do
    accepted =
      case declared do
        [] -> "It declares no flags."
        flags -> "Its flags: " <> Enum.map_join(flags, " ", &("--" <> dashed(&1)))
      end

    """
    Unknown flag #{switch} for recipe #{root}. #{accepted}

    See them with: mix composer.recipe.show #{root}
    """
  end

  def message({:recipes_subdir, path}) do
    "#{path} is a directory. Recipe groups are .exs files directly under recipes/; nested groups are not supported."
  end

  def message({:legacy_recipes_dir, path}) do
    "#{path} is no longer read. Recipe groups now live under recipes/; rename the directory."
  end

  def message({:legacy_templates_dir, path}) do
    """
    #{path} is no longer read. Templates now live beside the step that uses \
    them: move each file to steps/_<id>/ (next to steps/<id>.ex), refer to it \
    with template/1 relative to that directory, and remove templates/.
    """
  end

  def message({:orphaned_templates, dir, step}) do
    owner =
      if step,
        do: "#{step} does not exist",
        else: "it is not a step's template directory"

    """
    #{dir} holds files that no step owns: #{owner}. A step's templates live \
    in the directory named after its file with a leading underscore \
    (steps/_<id>/ beside steps/<id>.ex). Move them beside the step that \
    uses them, or delete them.
    """
  end

  def message({:unprefixed_templates, dir, template_dir}) do
    """
    #{dir} holds templates of #{dir}.ex, but a step's template directory is \
    named after its file with a leading underscore. Rename it to \
    #{template_dir}; template/1 paths stay the same.
    """
  end

  def message({:not_a_step, path}) do
    """
    #{path} is a .ex file under steps/ that is not a step module. Every .ex \
    file there is compiled with the package and taken to be a step. If it \
    is a template, rename it to #{Path.basename(path)}.eex.
    """
  end

  def message({:missing_template, ref, path, file}) do
    "#{ref}: template #{inspect(path)} does not exist (looked for #{file})."
  end

  def message({:group_recipe_clash, cookbook, name}) do
    "#{cookbook} has a recipe group #{name} and a recipe named #{name}. Rename one, so #{cookbook}:#{name} is never ambiguous."
  end

  def message({:legacy_form, ref, entry, suggestion}) do
    """
    Recipe #{ref} uses an old step form: #{format(entry)}

    Write it as #{suggestion} instead. Steps are now referenced by string, \
    "cookbook:path" (or an unqualified "path"), and recipes with \
    {:use, "cookbook:path"}.
    """
  end

  def message({:unknown_entry_option, ref, entry, key}) do
    """
    Recipe #{ref} has an unknown option #{key}: in #{format(entry)}

    A step takes if: and argv:. A hex: package also takes only:, runtime:, \
    one source (version:, github:, git: or path:) and, with github: or \
    git:, ref:, branch:, tag:, sparse: and submodules:.
    """
  end

  def message({:bad_entry_option, ref, entry, key, value}) do
    expected =
      case key do
        :if -> "a flag atom, e.g. if: :oban_pro"
        :argv -> ~s(a list of strings, e.g. argv: ["--opt", "value"])
        :only -> "an environment atom or a list of them, e.g. only: :dev or only: [:dev, :test]"
        :runtime -> "a boolean"
        :submodules -> "a boolean"
        :version -> ~s(a version requirement, e.g. version: "~> 3.5")
        :github -> ~s(an "owner/repo" string)
        _ -> "a non-empty string"
      end

    "Recipe #{ref} has an invalid #{key}: #{inspect(value, limit: 10)} in #{format(entry)}. Expected #{expected}."
  end

  def message({:hex_only_option, ref, entry, key}) do
    {written, _opts} = entry

    """
    Recipe #{ref} gives #{key}: to the step #{inspect(written)}: #{format(entry)}

    #{key}: is a package option, for hex: entries only. A step takes if: \
    and argv:. If you meant a Hex package, write {"hex:...", #{key}: ...}.
    """
  end

  def message({:multiple_sources, ref, entry, keys}) do
    """
    Recipe #{ref} gives more than one source (#{Enum.map_join(keys, ", ", &"#{&1}:")}) \
    in #{format(entry)}. Keep one of version:, github:, git: and path:.
    """
  end

  def message({:git_option_without_git, ref, entry, key}) do
    "Recipe #{ref} gives #{key}: without a github: or git: source in #{format(entry)}. " <>
      "#{key}: refines a git dependency; add github: or git:, or remove #{key}:."
  end

  def message({:multiple_git_refs, ref, entry, keys}) do
    "Recipe #{ref} gives #{Enum.map_join(keys, " and ", &"#{&1}:")} in #{format(entry)}. " <>
      "A git dependency takes at most one of ref:, branch: and tag:."
  end

  def message({:source_conflict, ref, entry}) do
    {written, _opts} = entry

    """
    Recipe #{ref} gives #{inspect(written)} a source twice: once after the @ \
    and once as an option, in #{format(entry)}. Keep one; in a recipe, the \
    option is preferred (e.g. {"hex:ash", version: "~> 3.5"}).
    """
  end

  def message({:repo_source, ref, entry, key}) do
    "Recipe #{ref} gives a #{key}: source to a private-repo package (org.pkg) in " <>
      "#{format(entry)}. A repo package comes from its repo; give it a version: or nothing."
  end

  def message({:invalid_entry, ref, entry}) do
    """
    Invalid entry in recipe #{ref}: #{format(entry)}

    Expected one of:

        "cookbook:path"                  # a step
        {"cookbook:path", if: :flag}     # a step that runs only with --flag
        {"cookbook:path", argv: ["--opt"], if: :flag}
        "hex:pkg"                        # a package, and its installer
        {"hex:pkg", argv: ["--opt"], only: :dev, version: "~> 1.0"}
        {:use, "cookbook:group/name"}    # another recipe, in place
        {:use, "name"}                   # a recipe in the same group
        {:use, "cookbook:group/name", if: :flag}
        {:task, "x.y", ["arg"]}          # compose an Igniter task
        {:queue, "x.y", ["arg"]}         # run a Mix task after changes apply
    """
  end

  def message({:local_recipes_only, dir, entry}) do
    """
    Local holds recipes only, but #{Path.join(dir, entry)} exists.

    #{dir} holds your recipe groups under recipes/. Put personal steps or \
    templates in a cookbook package added as a path dependency (see \
    mix composer.gen.cookbook), and remove #{entry}/.
    """
  end

  def message({:local_unrecognized, dir, entry}) do
    "#{Path.join(dir, entry)} is not recognized. Your config directory holds recipe groups under recipes/ only."
  end

  def message({:config_dir_not_dir, path}) do
    """
    The composer config path #{path} is a file, not a directory.

    The config is a directory holding your recipe groups under recipes/ \
    (e.g. recipes/ash.exs, holding local:ash/base, local:ash/auth, ...). \
    A single recipes.exs file is no longer supported; create a recipe with:

        mix composer.gen.recipe my_group/my_recipe --local
    """
  end

  def message({:config_dir_missing, path}) do
    """
    The composer config directory #{path} does not exist.

    It was given with -c or COMPOSER_CONFIG. Create it, or create a first \
    recipe in it with:

        mix composer.gen.recipe my_group/my_recipe --local -c #{path}
    """
  end

  def message({:duplicate_cookbook, name, modules}) do
    """
    More than one cookbook is named #{inspect(name)}: #{Enum.map_join(modules, ", ", &inspect/1)}.

    A cookbook is named after its package, so each name must come from one \
    package. Remove one of them from your dependencies, or exclude it with \
    config :composer, cookbooks: [except: [...]].
    """
  end

  def message({:local_step, ref, origin}) do
    "#{where(origin)}#{inspect(ref)} names a step in local, which holds recipes only. Reference a package cookbook's step instead."
  end

  def message({:dep_opts_on_step, written, step_ref, origin, keys}) do
    """
    #{where(origin)}#{inspect(written)} names the step #{step_ref}, but has \
    package options #{Enum.map_join(keys, ", ", &"#{&1}:")}. Those are only \
    for a Hex package. Remove them, or, if you meant the package, write \
    {#{inspect("hex:" <> Path.basename(written))}, ...}.
    """
  end

  def message({:conflicting_install, package, installs}) do
    """
    The package #{package} is installed more than once, with different options:

    #{Enum.map_join(installs, "\n", fn {origin, label} -> "    #{label}  (#{origin || "the command line"})" end)}

    Composer adds one dependency per package and runs its installer once. \
    Give every hex:#{package} entry the same options, or keep just one.
    """
  end

  def message({:unknown_cookbook, name, ref, origin, known}) do
    """
    #{where(origin)}#{inspect(ref)} names the cookbook #{inspect(name)}, which is not installed.

    Available cookbooks: #{Enum.join(Enum.sort(known), ", ")}

    If #{name} is a package that ships a composer cookbook, add it to your \
    dependencies, e.g. {:#{name}, "~> x.y", only: :dev}, and run mix deps.get.
    #{alias_hint(name, origin)}\
    """
  end

  def message({:missing_step, ref, origin, suggestions}) do
    "#{where(origin)}no step matches #{inspect(ref)}.\n\n" <>
      suggest(suggestions, "List steps with: mix composer.step.list")
  end

  def message({:typo, ref, origin, suggestions}) do
    """
    #{where(origin)}no step matches #{inspect(ref)}.

    Did you mean: #{Enum.join(suggestions, ", ")}?

    An unqualified name that matches no step is installed as a Hex package, \
    but #{inspect(ref)} looks like a typo of a step name. If you meant the \
    package, write #{inspect("hex:" <> ref)}.
    """
  end

  def message({:ambiguous, kind, ref, origin, candidates}) do
    """
    #{where(origin)}#{inspect(ref)} matches a #{kind} in more than one cookbook:

    #{Enum.map_join(candidates, "\n", &"    #{&1}")}

    Qualify the reference with its cookbook, e.g. #{inspect(hd(candidates))}.
    """
  end

  def message({:missing_recipe, ref, origin, suggestions}) do
    hint =
      if String.contains?(ref, "/"),
        do: "",
        else:
          if(origin,
            do: "An unqualified name refers to a recipe in the same group.\n\n",
            else:
              "Recipes are addressed as \"cookbook:group/name\" (e.g. \"local:ash/base\").\n\n"
          )

    "#{where(origin)}no recipe matches #{inspect(ref)}.\n\n" <>
      hint <> suggest(suggestions, "List recipes with: mix composer.recipe.list")
  end

  def message({:cycle, path}) do
    "Include cycle: " <> Enum.join(path, " -> ")
  end

  def message({:reserved_flag, flag}) do
    "Flag :#{flag} is reserved by mix composer.recipe.run; rename the #{flag}: flag (and its if: :#{flag}) in your recipes"
  end

  def message({:requires_unmet, failures}) do
    "Pre-flight checks failed, so nothing was run:\n\n" <>
      Enum.map_join(failures, "\n", &("  * " <> &1))
  end

  def message(:not_in_project) do
    """
    This task must be run inside a Mix project (no mix.exs was found).

    Run from an editor, it runs in the editor's working directory: start \
    your editor from the host project (cd my_app && nvim ...).
    """
  end

  def message({:step_missing_meta, step_ref, _module, key}) do
    "#{step_ref}: no #{key}. Add `#{key}: ...` to its `use Composer.Step` options."
  end

  def message({:missing_step_test, step_ref, _module, path}) do
    "#{step_ref}: no test. Add #{path}."
  end

  def message({:requires_unresolved, step_ref, _module, ref, reason}) do
    "#{step_ref}: requires #{inspect(ref)}, which does not resolve: " <>
      String.trim(message(reason))
  end

  def message({:manifest_missing, path}) do
    "#{Path.relative_to_cwd(path)} is missing. Run mix composer.cookbook.manifest."
  end

  def message({:manifest_stale, path}) do
    "#{Path.relative_to_cwd(path)} is out of date. Run mix composer.cookbook.manifest."
  end

  def message({:empty_group, path}) do
    "Recipe group #{path} is empty."
  end

  def message({:unused_alias, recipe_ref, name, target}) do
    "#{recipe_ref}: alias #{name} (= #{target}) is never used. Remove it, or use it."
  end

  def message({:inconsistent_alias, path, name, uses}) do
    where =
      Enum.map_join(uses, ", ", fn {target, recipe_ref} ->
        "#{target} in #{recipe_id(recipe_ref)}"
      end)

    "Recipe group #{path}: alias #{name} names different cookbooks: #{where}."
  end

  def message({:step_recipe_clash, ref}) do
    "#{ref} is both a step and a recipe. That is allowed " <>
      "(position decides which is meant), but can confuse readers."
  end

  def message({:unused_template, step_ref, _module, file}) do
    "#{step_ref}: #{file} is never referred to by template/1. Remove it, or use it."
  end

  def message({:include_problems, _origin, _written, target, count}) do
    "#{target} has #{count} #{if count == 1, do: "problem", else: "problems"}."
  end

  def message(:gen_lsp_missing) do
    """
    mix composer.lsp needs the gen_lsp package, an optional dependency of \
    composer. Add it to your project's deps in mix.exs:

        {:gen_lsp, "~> 0.11.4", only: :dev}

    then run mix deps.get. See the Composer LSP guide \
    (guides/composer_lsp.md) for the editor setup.
    """
  end

  def message({:lint_file_missing, path}) do
    "#{path} does not exist. --file takes an existing recipe group file."
  end

  def message({:lint_file_unknown, path}) do
    """
    #{path} is not a recipe group of your local config or of an installed \
    cookbook. --file takes a file under the local config directory's \
    recipes/, or under a cookbook's lib/composer/<name>/recipes/.
    """
  end

  def message({:lint_file_mismatch, path, cookbook}) do
    "--local was given, but #{path} belongs to the cookbook #{cookbook}. Drop --local; --file finds the cookbook from the path."
  end

  def message(other), do: "composer error: #{inspect(other)}"

  @typedoc """
  What an error is about, for placing it in a file (see `anchor/1`).
  """
  @type anchor ::
          {:ref, String.t() | nil, String.t()}
          | {:entry, String.t(), term()}
          | {:recipe_key, String.t(), atom() | {:if, atom()}}
          | {:alias, String.t(), atom()}
          | {:recipe, String.t()}
          | {:recipe_name, Path.t(), String.t() | atom()}
          | {:recipe_named, String.t(), String.t()}
          | {:cycle, [String.t()]}
          | {:install, String.t(), [{String.t() | nil, String.t()}]}
          | {:file, Path.t()}
          | {:file, Path.t(), pos_integer() | nil}
          | {:step, String.t()}
          | {:step, String.t(), {:template | :requires | :test, String.t()}}
          | nil

  @doc """
  Returns what an error is about: not a position, but the thing to look
  for, which `Composer.Lint` turns into a file and a range.

    * `{:ref, origin, written}` - a reference as written in recipe
      `origin` (`nil` when the error does not say; the recipe being
      checked is meant)
    * `{:entry, recipe_ref, entry}` - a whole step entry
    * `{:recipe_key, recipe_ref, key}` - one of a recipe's keys;
      `{:if, flag}` for an `if:` flag
    * `{:alias, recipe_ref, name}` - a cookbook alias
    * `{:recipe, recipe_ref}` - a recipe's name key
    * `{:recipe_name, path, name}` - every name key `name` in a group file
    * `{:recipe_named, cookbook, name}` - a recipe named `name` in any
      group of `cookbook`
    * `{:cycle, chain}` - the include that closes a cycle
    * `{:install, package, [{origin, label}]}` - the installs of a package
    * `{:file, path}` / `{:file, path, line}` - a file, or one of its lines
    * `{:step, step_ref}` / `{:step, step_ref, detail}` - a step's source,
      at its `use Composer.Step`, a `template/1` path or a `requires` ref
    * `nil` - nothing to point at

  A new error kind gets a `message/1` clause *and* an `anchor/1` clause;
  a test checks that every `message/1` tag has one.
  """
  @spec anchor(term()) :: anchor() | :unknown
  def anchor({:invalid_ref, written, _why}), do: {:ref, nil, written}

  def anchor({:recipe_eval, _ref, path, _exception, line}), do: {:file, path, line}
  def anchor({:group_read, path, _reason}), do: {:file, path}
  def anchor({:group_parse, path, _description, line}), do: {:file, path, line}
  def anchor({:group_shape, path, _term}), do: {:file, path}
  def anchor({:invalid_group_name, path}), do: {:file, path}
  def anchor({:invalid_recipe_name, path, name}), do: {:recipe_name, path, name}
  def anchor({:recipe_shape, ref, _term}), do: {:recipe, ref}
  def anchor({:recipe_missing_key, ref, key}), do: {:recipe_key, ref, key}
  def anchor({:unknown_recipe_key, ref, key}), do: {:recipe_key, ref, key}
  def anchor({:bad_recipe_value, ref, key, _value}), do: {:recipe_key, ref, key}
  def anchor({:invalid_alias, ref, name}), do: {:alias, ref, name}
  def anchor({:reserved_alias, ref, name}), do: {:alias, ref, name}
  def anchor({:duplicate_alias, ref, name}), do: {:alias, ref, name}
  def anchor({:alias_atom_target, ref, name, _target}), do: {:alias, ref, name}
  def anchor({:invalid_alias_target, ref, name, _target}), do: {:alias, ref, name}
  def anchor({:alias_shadows_cookbook, ref, name}), do: {:alias, ref, name}

  def anchor({:unknown_alias_target, written, _name, _target, origin, _known}),
    do: {:ref, origin, written}

  def anchor({:via_alias, written, _name, _target, reason}) do
    case anchor(reason) do
      {:ref, origin, _lookup} -> {:ref, origin, written}
      other -> other
    end
  end

  def anchor({:multiline_shortdoc, ref}), do: {:recipe_key, ref, :shortdoc}
  def anchor({:duplicate_recipe, path, name}), do: {:recipe_name, path, name}
  def anchor({:undeclared_flag, ref, flag}), do: {:recipe_key, ref, {:if, flag}}
  def anchor({:recipes_subdir, path}), do: {:file, path}
  def anchor({:legacy_recipes_dir, path}), do: {:file, path}
  def anchor({:legacy_templates_dir, path}), do: {:file, path}
  def anchor({:orphaned_templates, dir, _step}), do: {:file, dir}
  def anchor({:unprefixed_templates, dir, _template_dir}), do: {:file, dir}
  def anchor({:not_a_step, path}), do: {:file, path}
  def anchor({:missing_template, ref, path, _file}), do: {:step, ref, {:template, path}}
  def anchor({:group_recipe_clash, cookbook, name}), do: {:recipe_named, cookbook, name}

  def anchor({tag, ref, entry})
      when tag in [:legacy_form, :invalid_entry, :source_conflict],
      do: {:entry, ref, entry}

  def anchor({:legacy_form, ref, entry, _suggestion}), do: {:entry, ref, entry}

  def anchor({tag, ref, entry, _key})
      when tag in [
             :unknown_entry_option,
             :hex_only_option,
             :multiple_sources,
             :git_option_without_git,
             :multiple_git_refs,
             :repo_source
           ],
      do: {:entry, ref, entry}

  def anchor({:bad_entry_option, ref, entry, _key, _value}), do: {:entry, ref, entry}
  def anchor({:local_recipes_only, dir, entry}), do: {:file, Path.join(dir, entry)}
  def anchor({:local_unrecognized, dir, entry}), do: {:file, Path.join(dir, entry)}
  def anchor({:local_step, ref, origin}), do: {:ref, origin, ref}

  def anchor({:dep_opts_on_step, written, _step_ref, origin, _keys}),
    do: {:ref, origin, written}

  def anchor({:conflicting_install, package, installs}), do: {:install, package, installs}
  def anchor({:unknown_cookbook, _name, ref, origin, _known}), do: {:ref, origin, ref}
  def anchor({:missing_step, ref, origin, _suggestions}), do: {:ref, origin, ref}
  def anchor({:typo, ref, origin, _suggestions}), do: {:ref, origin, ref}
  def anchor({:ambiguous, _kind, ref, origin, _candidates}), do: {:ref, origin, ref}
  def anchor({:missing_recipe, ref, origin, _suggestions}), do: {:ref, origin, ref}
  def anchor({:cycle, chain}), do: {:cycle, chain}
  def anchor({:step_missing_meta, step_ref, _module, _key}), do: {:step, step_ref}

  def anchor({:missing_step_test, step_ref, _module, path}),
    do: {:step, step_ref, {:test, path}}

  def anchor({:requires_unresolved, step_ref, _module, ref, _reason}),
    do: {:step, step_ref, {:requires, ref}}

  def anchor({:manifest_missing, path}), do: {:file, path}
  def anchor({:manifest_stale, path}), do: {:file, path}
  def anchor({:empty_group, path}), do: {:file, path}
  def anchor({:unused_alias, ref, name, _target}), do: {:alias, ref, name}
  def anchor({:inconsistent_alias, _path, name, [{_target, ref} | _]}), do: {:alias, ref, name}
  def anchor({:step_recipe_clash, ref}), do: {:recipe, ref}
  def anchor({:unused_template, _step_ref, _module, file}), do: {:file, file}
  def anchor({:include_problems, origin, written, _target, _count}), do: {:ref, origin, written}

  # Not lint problems: command-line, configuration and run-time errors.
  def anchor({:unknown_flag, _switch, _root, _declared}), do: nil
  def anchor({:reserved_flag, _flag}), do: nil
  def anchor({:requires_unmet, _failures}), do: nil
  def anchor({:config_dir_not_dir, _path}), do: nil
  def anchor({:config_dir_missing, _path}), do: nil
  def anchor({:duplicate_cookbook, _name, _modules}), do: nil
  def anchor({:lint_file_missing, _path}), do: nil
  def anchor({:lint_file_unknown, _path}), do: nil
  def anchor({:lint_file_mismatch, _path, _cookbook}), do: nil
  def anchor(:not_in_project), do: nil
  def anchor(:gen_lsp_missing), do: nil

  def anchor(_other), do: :unknown

  @doc "Returns a human-readable message for a resolver warning."
  @spec warning({atom(), term(), term()} | {atom(), term(), term(), term()}) :: String.t()
  def warning({:phase_order, entry, earlier}) do
    "#{entry.label} (phase #{entry.meta.phase}) runs after #{earlier.label} " <>
      "(phase #{earlier.meta.phase}); #{entry.meta.phase} steps normally run first"
  end

  def warning({:provides_overlap, capability, entries}) do
    "#{Enum.map_join(entries, ", ", & &1.label)} all provide #{inspect(capability)}"
  end

  def warning({:conflict, entry, capability, other}) do
    "#{entry.label} conflicts with #{inspect(capability)}, which #{other.label} provides"
  end

  def warning({:requires_order, entry, ref}) do
    "#{entry.label} requires #{ref}, which is not listed before it"
  end

  # Aliases are per recipe: one declared in an including recipe does not
  # apply inside the recipe it includes.
  defp alias_hint(_name, nil), do: ""

  defp alias_hint(name, origin),
    do: "\nIf #{name} is meant as a cookbook alias, declare it in #{origin}'s aliases:.\n"

  defp recipe_id(ref) do
    case String.split(ref, ":", parts: 2) do
      [_cookbook, id] -> id
      [id] -> id
    end
  end

  defp dashed(flag), do: String.replace(to_string(flag), "_", "-")

  defp where(nil), do: ""
  defp where(origin), do: "In recipe #{origin}: "

  defp suggest([], fallback), do: fallback

  defp suggest(suggestions, _fallback) do
    "Did you mean: #{Enum.join(Enum.take(suggestions, 10), ", ")}?"
  end

  defp format(entry), do: entry |> Macro.escape() |> Macro.to_string()
end
