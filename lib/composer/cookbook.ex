defmodule Composer.Cookbook do
  @moduledoc """
  Defines a cookbook: one package's tree of steps and recipes.

  Every cookbook is laid out the same way:

      lib/composer/cc_lab.ex                    # the cookbook module
      lib/composer/cc_lab/steps/astral/nav1.ex  # a step (use Composer.Step)
      lib/composer/cc_lab/steps/astral/_nav1/   # its templates
      lib/composer/cc_lab/recipes/**/*.exs      # chapters (see Composer.Recipe.Chapter)
      lib/composer/cc_lab/manifest.exs          # written by mix composer.cookbook.manifest

  A step's templates live in the directory named after its file (see
  `Composer.Templates`). There is no cookbook-level `templates/` directory.

  and declared with:

      defmodule Composer.CcLab do
        use Composer.Cookbook,
          summary: "Andy's composer steps",
          homepage: "https://github.com/andyl/cc_lab"
      end

  ## Naming

  The cookbook name comes from the module (`Composer.CcLab` is `cc_lab`)
  and must equal the package's OTP app name, so one package defines at most
  one cookbook and Hex's package uniqueness keeps cookbook names unique.
  The one exception is composer's own built-in cookbook, `cb_std`.

  These names are reserved and rejected at compile time: #{Enum.join(["cb_std", "hex", "local"], ", ")}
  and every top-level `Composer.*` module name (see `reserved/0`).

  ## Compile-time checks

  `use Composer.Cookbook` fails compilation, with a message that says how to
  fix it, when:

    * the module is nested (`Composer.Foo.Bar`) or its name does not match
      the app
    * the name is reserved
    * the module is not defined in `lib/composer/<name>.ex`
    * a chapter file under `recipes/` has an invalid name or does not parse
    * a `.ex` file under `steps/` is not a step (a template stored as bare
      `.ex` would be compiled as part of the package; rename it `.ex.eex`)

  Chapter files are external resources, and adding or removing a chapter or a
  file under `steps/` triggers a recompile. The `.ex` check is textual (the
  file must `use Composer.Step` and be named for its path), since step
  modules may not be compiled yet; `mix composer.cookbook.lint` checks the
  compiled modules.

  ## Runtime

  A cookbook is described at run time by a `%Composer.Cookbook{}` struct.
  `kind` is `:code` for a package's cookbook and `:virtual` for `hex`.
  Recipes and templates are read from `source_dir/1`, the cookbook's tree in the
  dependency's source, so composer is a development tool: running from a
  release is not supported.
  """

  alias Composer.Recipe.Chapter

  defstruct [:name, :app, :module, :kind, :summary, :homepage, :source_dir]

  @type kind :: :code | :virtual

  @type t :: %__MODULE__{
          name: String.t(),
          app: atom() | nil,
          module: module() | nil,
          kind: kind(),
          summary: String.t() | nil,
          homepage: String.t() | nil,
          source_dir: Path.t() | nil
        }

  # Composer's own top-level module names. A test asserts that every
  # top-level module composer ships is listed here.
  @module_names ~w(
    runner step cookbook templates helpers versions resolver ref recipe
    discovery manifest index completion facets error git cli preflight
    lint lsp editor
  )

  @reserved ["cb_std", "hex", "local" | @module_names]

  @doc "The cookbook names no package may use."
  @spec reserved() :: [String.t()]
  def reserved, do: @reserved

  defmacro __using__(opts) do
    {opts, _binding} = Code.eval_quoted(opts, [], __CALLER__)
    info = define!(__CALLER__, opts)

    resources = for file <- info.resources, do: quote(do: @external_resource(unquote(file)))

    quote do
      unquote_splicing(resources)

      @composer_cookbook_source_dir unquote(info.source_dir)
      @composer_cookbook_hash unquote(info.hash)

      @doc false
      def __composer_cookbook__ do
        unquote(
          Macro.escape(%{
            name: info.name,
            app: info.app,
            summary: opts[:summary],
            homepage: opts[:homepage],
            source_dir: info.source_dir,
            recipes: info.recipes
          })
        )
      end

      # @external_resource only notices edits to files that existed at
      # compile time; this makes an added or removed recipe, or file under
      # steps/, recompile the cookbook too.
      @doc false
      def __mix_recompile__? do
        Composer.Cookbook.listing_hash(@composer_cookbook_source_dir) !=
          @composer_cookbook_hash
      end
    end
  end

  # -- runtime ------------------------------------------------------------

  @doc "Builds the struct for a cookbook module."
  @spec from_module(module()) :: t()
  def from_module(module) do
    info = module.__composer_cookbook__()

    %__MODULE__{
      name: info.name,
      app: info.app,
      module: module,
      kind: :code,
      summary: info.summary,
      homepage: info.homepage,
      source_dir: info.source_dir
    }
  end

  @doc "The virtual `hex` cookbook."
  @spec hex() :: t()
  def hex do
    %__MODULE__{
      name: "hex",
      kind: :virtual,
      summary: "Hex packages, added to mix.exs and installed with their own installer"
    }
  end

  @doc """
  Returns the module a cookbook named `name` is defined by, e.g.
  `Composer.CcLab` for `"cc_lab"`.
  """
  @spec module_for(String.t()) :: module()
  def module_for(name), do: Module.concat(["Composer", Macro.camelize(name)])

  @doc "True when `module` is loaded and defines a cookbook."
  @spec cookbook_module?(module()) :: boolean()
  def cookbook_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__composer_cookbook__, 0)
  end

  @doc """
  Returns the cookbook's steps, sorted by id.

  The steps are the modules of the cookbook's app named
  `Composer.<Cookbook>.Steps.*` that define `__composer_step__/0`. Only the
  app's own module list is read; nothing is scanned.
  """
  @spec steps(t()) :: [Composer.Step.Meta.t()]
  def steps(%__MODULE__{kind: :code, module: module} = cookbook) do
    prefix = "Elixir." <> inspect(module) <> ".Steps."

    cookbook
    |> app_modules()
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), prefix))
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :__composer_step__, 0)))
    |> Enum.map(& &1.__composer_step__())
    |> Enum.sort_by(& &1.id)
  end

  def steps(%__MODULE__{}), do: []

  @doc "Finds a step by id."
  @spec step(t(), String.t()) :: {:ok, Composer.Step.Meta.t()} | :error
  def step(cookbook, id) do
    case Enum.find(steps(cookbook), &(&1.id == id)) do
      nil -> :error
      meta -> {:ok, meta}
    end
  end

  @doc """
  Returns the cookbook's recipe ids (`"chapter/name"`), sorted.

  Ids are read from each chapter file's syntax tree, without evaluating it.
  A chapter file that cannot be read this way is skipped; `load_recipes/1`
  reports it.
  """
  @spec recipes(t()) :: [String.t()]
  def recipes(%__MODULE__{} = cookbook) do
    ids =
      for {chapter, path} <- chapters(cookbook),
          {:ok, names} <- [Chapter.ids(path)],
          name <- names,
          do: chapter <> "/" <> name

    Enum.sort(ids)
  end

  @doc """
  Returns the cookbook's chapter files as `{chapter_path, file}`, sorted by
  chapter path. Files with an invalid chapter path are left out.
  """
  @spec chapters(t()) :: [{String.t(), Path.t()}]
  def chapters(%__MODULE__{kind: :virtual}), do: []

  def chapters(%__MODULE__{} = cookbook) do
    case source_dir(cookbook) do
      nil -> []
      dir -> dir |> chapter_files() |> Enum.filter(&Chapter.valid_path?(elem(&1, 0)))
    end
  end

  @doc """
  Returns the file of chapter `chapter` (a chapter path such as
  `"ash/ui"`), or `nil` when it does not exist.
  """
  @spec chapter_path(t(), String.t()) :: Path.t() | nil
  def chapter_path(%__MODULE__{} = cookbook, chapter) do
    case List.keyfind(chapters(cookbook), chapter, 0) do
      {_chapter, path} -> path
      nil -> nil
    end
  end

  @doc """
  Returns the chapter file holding recipe `id` (`"chapter/path/name"`), or
  `nil` when the chapter or the recipe does not exist. The last segment is
  the recipe name and the rest the chapter path; the filesystem is never
  probed to split it another way.
  """
  @spec recipe_path(t(), String.t()) :: Path.t() | nil
  def recipe_path(%__MODULE__{} = cookbook, id) do
    with {chapter, name} when chapter != "." <- {Path.dirname(id), Path.basename(id)},
         path when is_binary(path) <- chapter_path(cookbook, chapter),
         {:ok, names} <- Chapter.ids(path),
         true <- name in names do
      path
    else
      _ -> nil
    end
  end

  @doc """
  Evaluates every chapter file of the cookbook. Returns the valid recipes,
  sorted by id, and `{path, reason}` for each chapter, or recipe, that
  failed to load.
  """
  @spec load_recipes(t()) :: {[Composer.Recipe.t()], [{Path.t(), term()}]}
  def load_recipes(%__MODULE__{name: name} = cookbook) do
    cookbook
    |> chapters()
    |> Enum.reduce({[], []}, fn {_chapter, path}, {recipes, errors} ->
      case Chapter.load_all(path, name) do
        {:ok, {loaded, problems}} ->
          {recipes ++ loaded, errors ++ Enum.map(problems, &{path, &1})}

        {:error, reason} ->
          {recipes, errors ++ [{path, reason}]}
      end
    end)
    |> then(fn {recipes, errors} -> {Enum.sort_by(recipes, & &1.id), errors} end)
  end

  @doc false
  # Every chapter file, including ones with invalid paths, as {chapter, path};
  # and every directory under recipes/, as {relative path, path}. For lint.
  def recipe_entries(%__MODULE__{kind: :virtual}), do: {[], []}

  def recipe_entries(%__MODULE__{} = cookbook) do
    case source_dir(cookbook) do
      nil ->
        {[], []}

      dir ->
        root = Path.join(dir, "recipes")

        dirs =
          root
          |> Path.join("**")
          |> Path.wildcard()
          |> Enum.filter(&File.dir?/1)
          |> Enum.reject(&(&1 == root))
          |> Enum.sort()
          |> Enum.map(&{Path.relative_to(&1, root), &1})

        {chapter_files(dir), dirs}
    end
  end

  @doc false
  # Every file under steps/, as {step files (.ex), other files}, relative
  # to steps/. For lint.
  def step_entries(%__MODULE__{kind: :code} = cookbook) do
    case source_dir(cookbook) do
      nil ->
        {[], []}

      dir ->
        root = Path.join(dir, "steps")

        root
        |> step_listing()
        |> Enum.map(&Path.relative_to(&1, root))
        |> reject_git_ignored(root)
        |> Enum.split_with(&(Path.extname(&1) == ".ex"))
    end
  end

  def step_entries(%__MODULE__{}), do: {[], []}

  # Drops the files git ignores, such as an editor's `.expert/` log
  # directory; keeps them all when `root` is not in a git work tree.
  defp reject_git_ignored([], _root), do: []

  defp reject_git_ignored(files, root) do
    case System.cmd("git", ["-c", "core.quotePath=false", "check-ignore", "--" | files],
           cd: root,
           stderr_to_stdout: true
         ) do
      {output, 0} -> files -- String.split(output, "\n", trim: true)
      _ -> files
    end
  rescue
    ErlangError -> files
  end

  @doc """
  Returns the directory the cookbook's recipes and templates are read from.

  For a package cookbook, in order: the dependency's source path, the
  project root when the cookbook belongs to the current project, then the
  directory recorded at compile time.
  """
  @spec source_dir(t()) :: Path.t() | nil
  def source_dir(%__MODULE__{kind: :code, app: app, name: name, source_dir: recorded}) do
    relative = Path.join(["lib", "composer", name])

    candidates =
      if Mix.Project.get() do
        dep = Mix.Project.deps_paths()[app]
        own = if Mix.Project.config()[:app] == app, do: project_root()
        for root <- [dep, own], root != nil, do: Path.join(root, relative)
      else
        []
      end

    Enum.find(candidates, &File.dir?/1) || recorded
  end

  def source_dir(%__MODULE__{source_dir: dir}), do: dir

  @doc false
  # A hash of the chapter files and the files under steps/ in `dir`, used by
  # __mix_recompile__?/0 to notice added and removed files.
  def listing_hash(dir) do
    dir
    |> listing()
    |> Enum.map(&Path.relative_to(&1, dir))
    |> :erlang.phash2()
  end

  # -- compile time -------------------------------------------------------

  @doc false
  # Runs every compile-time check and returns what the cookbook module
  # records. Public so tests can exercise it.
  def define!(env, opts) do
    name = name!(env)
    app = Keyword.get_lazy(opts, :app, fn -> Mix.Project.get() && Mix.Project.config()[:app] end)

    check_name!(env, name, app)
    check_file!(env, name)

    source_dir = Path.rootname(env.file)
    chapters = chapter_files(source_dir)

    Enum.each(chapters, fn {chapter, path} ->
      check_chapter_name!(env, chapter, path)
      check_recipe_parses!(path)
    end)

    recipes =
      for {chapter, path} <- chapters,
          {:ok, names} <- [Chapter.ids(path)],
          name <- names,
          do: chapter <> "/" <> name

    source_dir
    |> Path.join("steps")
    |> step_listing()
    |> Enum.filter(&(Path.extname(&1) == ".ex"))
    |> Enum.each(&check_step_file!(env, &1))

    %{
      name: name,
      app: app,
      source_dir: source_dir,
      recipes: recipes,
      resources: Enum.map(chapters, &elem(&1, 1)),
      hash: listing_hash(source_dir)
    }
  end

  defp name!(env) do
    case Module.split(env.module) do
      ["Composer", segment] ->
        Macro.underscore(segment)

      _ ->
        compile_error!(env, """
        #{inspect(env.module)} cannot be a cookbook: a cookbook module is \
        Composer.<App>, one level below Composer, named after the package's \
        OTP app (Composer.CcLab for :cc_lab).

        Rename the module, and move its file to lib/composer/<app>.ex.
        """)
    end
  end

  defp check_name!(env, "cb_std", :composer), do: env

  defp check_name!(env, "cb_std", _app) do
    compile_error!(env, """
    The cookbook name "cb_std" is reserved for composer's built-in cookbook.

    Name the cookbook after your package's OTP app instead.
    """)
  end

  defp check_name!(env, name, app) do
    cond do
      name in @reserved ->
        compile_error!(env, """
        The cookbook name #{inspect(name)} is reserved by composer \
        (reserved: #{Enum.join(@reserved, ", ")}).

        A cookbook is named after its package's OTP app; a package whose app \
        name is reserved cannot ship a cookbook.
        """)

      is_nil(app) ->
        compile_error!(env, """
        #{inspect(env.module)} must be compiled inside a Mix project, so its \
        name can be checked against the project's app.
        """)

      name != Atom.to_string(app) ->
        compile_error!(env, """
        #{inspect(env.module)} defines the cookbook #{inspect(name)}, but this \
        package's OTP app is #{inspect(app)}.

        A cookbook is named after its package, so a package has exactly one. \
        Rename the module to #{inspect(module_for(Atom.to_string(app)))} and \
        move it to lib/composer/#{app}.ex.
        """)

      true ->
        env
    end
  end

  defp check_file!(env, name) do
    unless Path.basename(env.file) == name <> ".ex" and
             Path.basename(Path.dirname(env.file)) == "composer" do
      compile_error!(env, """
      #{inspect(env.module)} must be defined in lib/composer/#{name}.ex, \
      next to its lib/composer/#{name}/ tree, but it is in \
      #{Path.relative_to_cwd(env.file)}.
      """)
    end
  end

  defp check_chapter_name!(env, chapter, path) do
    unless Chapter.valid_path?(chapter) do
      compile_error!(env, """
      Chapter #{Path.relative_to_cwd(path)} has an invalid name. Every \
      directory and file name under recipes/ is a lowercase [a-z0-9_] \
      segment; rename it (for example lv-base.exs to lv_base.exs).
      """)
    end
  end

  # Parse only: a recipe is never evaluated at compile time.
  defp check_recipe_parses!(path) do
    case Code.string_to_quoted(File.read!(path), file: path) do
      {:ok, _quoted} ->
        :ok

      {:error, {location, message, token}} ->
        line = if is_list(location), do: Keyword.get(location, :line, 0), else: location

        raise CompileError,
          file: path,
          line: line,
          description:
            "chapter #{Path.relative_to_cwd(path)} does not parse: " <>
              error_text(message) <> error_text(token)
    end
  end

  defp error_text({prefix, suffix}), do: "#{prefix}#{suffix}"
  defp error_text(text), do: to_string(text)

  # A .ex file under steps/ is compiled with the package, so it must be a
  # step; a template stored as bare .ex would not be.
  defp check_step_file!(env, path) do
    step? = File.read!(path) =~ ~r/^\s*use Composer\.Step\b/m

    case Composer.Step.path_id(path) do
      {:ok, _} when step? ->
        :ok

      found ->
        named =
          case found do
            {:ok, {cookbook, id}} ->
              ", or make it a step named #{inspect(Composer.Step.module_for(cookbook, id))}"

            :error ->
              ""
          end

        compile_error!(env, """
        #{Path.relative_to_cwd(path)} is a .ex file under steps/ that is not \
        a step. Every .ex file there is compiled as part of this package, \
        and is taken to be a step.

        If it is a template, rename it to #{Path.basename(path)}.eex (it will \
        be rendered with EEx and written without the .eex extension)#{named}.
        """)
    end
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end

  # -- files --------------------------------------------------------------

  # Chapters are the .exs files anywhere under recipes/.
  defp chapter_files(dir) do
    root = Path.join(dir, "recipes")

    dir
    |> recipe_listing()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{Chapter.path(root, &1), &1})
    |> Enum.sort()
  end

  defp recipe_listing(dir) do
    dir
    |> Path.join("recipes/**/*.exs")
    |> Path.wildcard()
    |> Enum.sort()
  end

  # Every file under a steps/ directory: step modules and templates.
  defp step_listing(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  defp listing(dir), do: recipe_listing(dir) ++ step_listing(Path.join(dir, "steps"))

  defp project_root, do: Path.dirname(Mix.Project.project_file())

  defp app_modules(%__MODULE__{module: module, app: app}) do
    # A cookbook's modules normally belong to its app, but a test fixture is
    # compiled into another app; ask which app actually holds the module.
    app =
      case :application.get_application(module) do
        {:ok, owner} -> owner
        :undefined -> app
      end

    Application.load(app)

    case :application.get_key(app, :modules) do
      {:ok, modules} -> modules
      :undefined -> []
    end
  end
end
