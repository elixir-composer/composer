defmodule Composer.Step do
  @moduledoc """
  Defines a composer step.

  A step is an `Igniter.Mix.Task` that lives in a cookbook's `steps/`
  directory instead of under `Mix.Tasks`, so it composes into a run's single
  diff but never shows up in `mix help`.

      defmodule Composer.CcLab.Steps.Ash.Postgres do   # lib/composer/cc_lab/steps/ash/postgres.ex
        use Composer.Step,
          summary: "Adds AshPostgres",
          action: :add,
          frameworks: [:ash],
          capability: [:database],
          stability: :stable,
          requires: ["cc_lab:ash", {:executable, "psql"}]

        @impl Igniter.Mix.Task
        def igniter(igniter), do: ...
      end

  ## Identity

  The step's id is its path under `steps/` (`"ash/postgres"`), and its
  cookbook is the directory above `steps/` (`cc_lab`). Its reference is
  `"cc_lab:ash/postgres"`. The module name must match that path —
  `Composer.<Cookbook>.Steps.<Path...>` — or compilation fails.

  ## Options

  Every option is metadata; see `Composer.Facets` for the vocabulary.

    * `:summary` - a one-line description, also the default `@moduledoc`
    * `:action`, `:phase`, `:stability` - one facet value each
    * `:frameworks`, `:capability` - lists of facet values
    * `:tags` - free atoms or strings
    * `:requires` - step references, `{:executable, name}` and
      `{:package, name, requirement}` checked before a run
    * `:provides`, `:conflicts` - capability atoms used for overlap warnings
    * `:author`, `:license`, `:homepage` - strings

  Unknown facet values are compile-time warnings. A wrong type is a compile
  error.

  ## Templates

  A step's templates live in the directory named after its file with a
  leading underscore, and `template/1` takes a path relative to it:

      steps/cluster/gigalixir.ex               # Composer.Core.Steps.Cluster.Gigalixir
      steps/cluster/_gigalixir/some.conf.eex   # template("some.conf.eex") in Gigalixir
      steps/cluster/gigalixir/libcluster.ex    # a child step, Composer.Core.Steps.Cluster.Gigalixir.Libcluster

      Composer.Templates.copy_file(igniter, template("some.conf.eex"), "config/some.conf")

  The underscore keeps templates apart from child steps, so a step can
  have both. Step path segments never start with `_`. Every `.ex` file
  under `steps/` is compiled with the package, so Elixir source templates
  are stored as `.ex.eex`. `template/1` checks at compile time
  that the file or directory exists, and registers it as an external
  resource, so a typo fails `mix compile` and an edit recompiles the step.
  A path computed at run time (`template("components/\#{name}.astral")`) is
  only checked when the step runs. A path may not leave the step's
  directory: templates are never shared between steps.
  """

  @doc "Returns the step's metadata."
  @callback __composer_step__() :: Composer.Step.Meta.t()

  @path_pattern ~r{/lib/composer/([a-z0-9_]+)/steps/(.+)\.ex\z}

  defmacro __using__(opts) do
    meta = define!(__CALLER__, opts)

    quote do
      use Igniter.Mix.Task

      @behaviour Composer.Step
      @before_compile Composer.Step

      import Composer.Step, only: [template: 1]

      Module.register_attribute(__MODULE__, :composer_templates, accumulate: true)

      @composer_step unquote(Macro.escape(meta))

      @impl Composer.Step
      def __composer_step__, do: @composer_step
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    moduledoc =
      if Module.get_attribute(env.module, :moduledoc) == nil do
        summary = Module.get_attribute(env.module, :composer_step).summary

        quote do
          @moduledoc unquote(summary || false)
        end
      end

    templates = env.module |> Module.get_attribute(:composer_templates) |> Enum.reverse()

    quote do
      unquote(moduledoc)

      # The paths given to template/1, with :dynamic for a computed one.
      # Read by Composer.Lint.
      @doc false
      def __composer_templates__, do: unquote(Enum.uniq(templates))
    end
  end

  @doc """
  Returns a template reference, `{cookbook, step_id, path}`, to `path` in
  the calling step's template directory (`steps/_<id>/`, see `template_dir/1`).

  A literal path must exist at compile time; see "Templates" above.
  """
  defmacro template(path) do
    env = __CALLER__

    case Module.get_attribute(env.module, :composer_step) do
      %Composer.Step.Meta{cookbook: cookbook, id: id} ->
        dir = env.file |> Path.expand() |> dir()

        if is_binary(path) do
          file = check_template!(env, dir, path)
          # Function bodies are expanded while the module is still open, so
          # the attributes can be set from here.
          Module.put_attribute(env.module, :external_resource, file)
          Module.put_attribute(env.module, :composer_templates, path)
          {:{}, [], [cookbook, id, path]}
        else
          check_dir!(env, dir)
          Module.put_attribute(env.module, :composer_templates, :dynamic)
          quote do: {unquote(cookbook), unquote(id), unquote(path)}
        end

      nil ->
        compile_error!(env, "template/1 can only be used inside a module that uses Composer.Step")
    end
  end

  @doc """
  Returns the template directory of the step defined in `file`: the path
  without its `.ex`, with its last segment prefixed by `_`, e.g.
  `steps/cluster/_gigalixir/` for `steps/cluster/gigalixir.ex`.
  """
  @spec dir(Path.t()) :: Path.t()
  def dir(file), do: file |> Path.rootname(".ex") |> template_dir()

  @doc """
  Returns the template directory of the step `id`, relative to `steps/`:
  its last segment prefixed by `_`, e.g. `"ash/_postgres"` for
  `"ash/postgres"`. Also accepts a full path without the `.ex`.
  """
  @spec template_dir(String.t()) :: String.t()
  def template_dir(id) do
    case Path.dirname(id) do
      "." -> "_" <> id
      parent -> Path.join(parent, "_" <> Path.basename(id))
    end
  end

  defp check_template!(env, dir, path) do
    file = Path.expand(path, dir)

    cond do
      Path.type(path) != :relative or not String.starts_with?(file, dir <> "/") ->
        compile_error!(env, """
        #{inspect(env.module)}: template #{inspect(path)} is outside the step's \
        directory, #{Path.relative_to_cwd(dir)}/.

        A step's templates live in its own directory; they are not shared \
        between steps. Copy the file beside this step.
        """)

      not File.exists?(file) ->
        compile_error!(env, """
        #{inspect(env.module)}: template #{inspect(path)} does not exist.

        Looked for #{file}. A step's templates live in the directory named \
        after its file with a leading underscore (#{Path.relative_to_cwd(dir)}/).
        """)

      true ->
        file
    end
  end

  defp check_dir!(env, dir) do
    unless File.dir?(dir) do
      compile_error!(env, """
      #{inspect(env.module)} uses template/1, but its template directory \
      #{dir} does not exist.
      """)
    end
  end

  @doc """
  Splits a step source path into `{cookbook, id}`, e.g.
  `".../lib/composer/cc_lab/steps/ash/postgres.ex"` gives
  `{"cc_lab", "ash/postgres"}`. Returns `:error` when the file is not under
  a `lib/composer/<cookbook>/steps/` directory.
  """
  @spec path_id(Path.t()) :: {:ok, {String.t(), String.t()}} | :error
  def path_id(file) do
    case Regex.run(@path_pattern, file, capture: :all_but_first) do
      [cookbook, id] ->
        if Regex.match?(~r/\A[a-z0-9_]+\z/, cookbook) and
             Enum.all?(String.split(id, "/"), &Regex.match?(~r/\A[a-z0-9][a-z0-9_]*\z/, &1)),
           do: {:ok, {cookbook, id}},
           else: :error

      _ ->
        :error
    end
  end

  @doc """
  Returns the module a step at `id` in `cookbook` must be named, e.g.
  `Composer.CcLab.Steps.Ash.Postgres` for `{"cc_lab", "ash/postgres"}`.
  """
  @spec module_for(String.t(), String.t()) :: module()
  def module_for(cookbook, id) do
    segments = id |> String.split("/") |> Enum.map(&Macro.camelize/1)
    Module.concat(["Composer", Macro.camelize(cookbook), "Steps" | segments])
  end

  @doc false
  # Validates the options and derives the step's identity. Public so tests
  # can exercise it, and so the Mix task shim can reuse it later.
  def define!(env, opts) do
    {cookbook, id} =
      case path_id(env.file) do
        {:ok, found} ->
          found

        :error ->
          compile_error!(env, """
          #{inspect(env.module)} uses Composer.Step, but #{Path.relative_to_cwd(env.file)} \
          is not inside a cookbook's steps/ directory.

          Steps live at lib/composer/<cookbook>/steps/<path>.ex, and their id is \
          the path under steps/ (lowercase [a-z0-9_] segments). A segment may \
          not start with _, which marks a step's template directory.
          """)
      end

    expected = module_for(cookbook, id)

    if env.module != expected do
      compile_error!(env, """
      #{inspect(env.module)} is defined in #{Path.relative_to_cwd(env.file)}, \
      so it must be named #{inspect(expected)}.

      A step's module name mirrors its path under steps/. Rename the module, \
      or move the file to match it.
      """)
    end

    # Options are data, but may use aliases or sigils, so evaluate them in
    # the caller's environment rather than requiring a literal.
    {opts, _binding} = Code.eval_quoted(opts, [], env)

    facets =
      case Composer.Facets.validate(opts) do
        {:ok, facets, warnings} ->
          Enum.each(warnings, &IO.warn("#{inspect(env.module)}: #{&1}", env))
          facets

        {:error, message} ->
          compile_error!(env, "#{inspect(env.module)}: #{message}")
      end

    struct!(
      Composer.Step.Meta,
      Map.merge(facets, %{
        id: id,
        ref: Composer.Ref.id(cookbook, id),
        cookbook: cookbook,
        module: env.module
      })
    )
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end
