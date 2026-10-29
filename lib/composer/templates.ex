defmodule Composer.Templates do
  @moduledoc """
  Helpers for steps that write files from templates.

  A step's templates live beside it, in the directory named after its file
  with a leading underscore (`Composer.Step.template_dir/1`):

      lib/composer/cb_std/steps/sidebar_layout.ex
      lib/composer/cb_std/steps/_sidebar_layout/app_fn.ex.eex
      lib/composer/cb_std/steps/_sidebar_layout/files/...

  Inside a step, `template/1` (imported by `use Composer.Step`) refers to a
  file or directory there, and is checked at compile time:

      def igniter(igniter) do
        igniter
        |> Composer.Templates.require_present({:dep, :heroicons}, "the sidebar layout uses heroicons")
        |> Composer.Templates.copy_dir(template("files"), ".")
        |> Composer.Templates.replace_function(
          Module.concat([Composer.Templates.assigns(igniter).web_module, "Layouts"]),
          :app,
          1,
          template("app_fn.ex.eex")
        )
      end

  A reference is `{cookbook, step_id, path}`. Code outside a step, such as a
  helper module shared by a cookbook's steps, builds one with `ref/2`.

  ## Rendering

  Only files ending in `.eex` are rendered, with EEx, and written without
  the `.eex` extension. Every other file is copied verbatim, so templates
  that contain their own `<%= %>` tags (a HEEx or Astral template) are safe.
  Elixir source must be stored as `.ex.eex`: a bare `.ex` file in a step's
  directory is a child step, compiled as part of the package, so
  `use Composer.Cookbook` rejects one that is not a step.

  `.eex` templates see the assigns as `@name`. `assigns/1` builds the
  standard ones, and every helper merges caller-given assigns over them.

  ## Path variables

  A path segment such as `__web_dir__` is replaced with the matching assign,
  so `lib/__web_dir__/components/layouts.ex.eex` is written to
  `lib/my_app_web/components/layouts.ex`. A variable with no assign raises,
  naming the variable and the template; nothing is written with a literal
  `__var__` in its path.

  ## Existing files

  A target file that exists is overwritten by default; the change is still
  shown in the Igniter diff before anything is written. Pass
  `on_exists: :skip` to leave existing files alone.
  """

  alias Composer.Cookbook

  @typedoc "A template: `{cookbook, step_id, path}`, `path` relative to the step's template directory."
  @type template_ref :: {atom() | String.t(), String.t(), String.t()}

  @var ~r/__([a-z][a-z0-9_]*?)__/

  @doc """
  Returns the standard assigns for the target app:

      %{app_name: "my_app", app_module: "MyApp", web_module: "MyAppWeb", web_dir: "my_app_web"}
  """
  @spec assigns(Igniter.t()) :: map()
  def assigns(igniter) do
    app_name = igniter |> Igniter.Project.Application.app_name() |> to_string()

    %{
      app_name: app_name,
      app_module: Composer.Edit.Project.app_module(igniter),
      web_module: Composer.Edit.Project.app_web_module(igniter),
      web_dir: app_name <> "_web"
    }
  end

  @doc """
  Returns a reference to `path` in the template directory of `step`, a
  step module.

  This is how code outside a step refers to a step's templates:

      Composer.Templates.ref(Composer.CcLab.Steps.Astral.DaisyComponents, "components/button.astral")
      #=> {"cc_lab", "astral/daisy_components", "components/button.astral"}

  Inside a step, use `template/1`, which is also checked at compile time.
  Raises when `step` is not a step module.
  """
  @spec ref(module(), Path.t()) :: template_ref()
  def ref(step, path) when is_atom(step) and is_binary(path) do
    if Code.ensure_loaded?(step) and function_exported?(step, :__composer_step__, 0) do
      %{cookbook: cookbook, id: id} = step.__composer_step__()
      {cookbook, id, path}
    else
      raise ArgumentError, "#{inspect(step)} is not a step module (it does not use Composer.Step)"
    end
  end

  @doc """
  Returns the absolute path of a template, raising when its cookbook or the
  file does not exist.
  """
  @spec path(template_ref()) :: Path.t()
  def path({cookbook, id, relative}) do
    cookbook = to_string(cookbook)
    path = Path.join(step_dir(cookbook, id), relative)

    if File.exists?(path) do
      path
    else
      raise ArgumentError,
            "template #{inspect(relative)} of #{inspect(Composer.Step.module_for(cookbook, id))} " <>
              "not found: #{path} does not exist"
    end
  end

  def path({_cookbook, relative}) do
    raise ArgumentError,
          "template reference #{inspect(relative)} has no step. Cookbook-level templates/ " <>
            "were removed: templates live beside their step, in steps/_<id>/. Use " <>
            "template/1 inside the step, or Composer.Templates.ref/2 elsewhere."
  end

  @doc """
  Writes one template to `target`, rendering it when it ends in `.eex`.

  `target` may contain path variables, and loses a trailing `.eex`.

  ## Options

    * `:assigns` - merged over `assigns/1`
    * `:on_exists` - `:overwrite` (default) or `:skip`
  """
  @spec copy_file(Igniter.t(), template_ref(), Path.t(), keyword()) :: Igniter.t()
  def copy_file(igniter, template_ref, target, opts \\ []) do
    source = path(template_ref)
    assigns = merged_assigns(igniter, opts)
    target = target |> expand_path(assigns, source) |> strip_eex()

    write(igniter, target, render(source, assigns), opts)
  end

  @doc """
  Writes every file under a template directory into `target_dir`, keeping
  the relative layout. `.gitkeep` files are skipped. Options are as for
  `copy_file/4`.
  """
  @spec copy_dir(Igniter.t(), template_ref(), Path.t(), keyword()) :: Igniter.t()
  def copy_dir(igniter, template_ref, target_dir, opts \\ []) do
    dir = path(template_ref)
    assigns = merged_assigns(igniter, opts)

    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&(Path.basename(&1) == ".gitkeep"))
    |> Enum.sort()
    |> Enum.reduce(igniter, fn source, igniter ->
      relative = source |> Path.relative_to(dir) |> expand_path(assigns, source) |> strip_eex()
      target = target_dir |> Path.join(relative) |> Path.relative_to(".")
      write(igniter, target, render(source, assigns), opts)
    end)
  end

  @doc """
  Replaces function `name/arity` of `module` with the rendered template, a
  complete `def`.

  A missing function or module is a warning, not a crash, since the target
  app may have been customized. Pass `warning:` in `opts` to word it.
  """
  @spec replace_function(
          Igniter.t(),
          module(),
          atom(),
          arity(),
          template_ref(),
          map() | keyword(),
          keyword()
        ) ::
          Igniter.t()
  def replace_function(igniter, module, name, arity, template_ref, assigns \\ %{}, opts \\ []) do
    source = path(template_ref)
    code = render(source, Map.merge(assigns(igniter), Map.new(assigns)))
    replacement = Sourceror.parse_string!(code)

    warning =
      Keyword.get(
        opts,
        :warning,
        "#{inspect(module)} has no #{name}/#{arity} function — skipped replacing it with #{elem(template_ref, 2)}."
      )

    igniter
    |> Igniter.Project.Module.find_and_update_module(module, fn zipper ->
      case move_to_def(zipper, name, arity) do
        {:ok, zipper} -> {:ok, Sourceror.Zipper.replace(zipper, replacement)}
        :error -> {:warning, warning}
      end
    end)
    |> case do
      {:ok, igniter} ->
        igniter

      {:error, igniter} ->
        Igniter.add_warning(igniter, "#{inspect(module)} not found — #{warning}")
    end
  end

  @doc """
  Adds `content` to the file at `path`:

    * `at: {:after, anchor}` - right after the first occurrence of `anchor`
    * `at: {:before, anchor}` - right before it
    * `at: :append` - at the end of the file

  Content already in the file is not added again. A missing file or anchor
  is a loud warning rather than a silent no-op, so drift in the target
  surfaces. Pass `warning:` to word it.
  """
  @spec insert(Igniter.t(), Path.t(), String.t(), keyword()) :: Igniter.t()
  def insert(igniter, path, content, opts) do
    at = Keyword.fetch!(opts, :at)
    warning = Keyword.get_lazy(opts, :warning, fn -> missing_anchor(at, path) end)

    if present?(igniter, path, content) do
      igniter
    else
      Composer.Edit.Files.update_checked(igniter, path, &insert_at(&1, content, at), warning)
    end
  end

  @doc """
  Adds a warning when a prerequisite is missing: `{:dep, name}` for a
  dependency in `mix.exs`, or `{:file, path}`.
  """
  @spec require_present(Igniter.t(), {:dep, atom()} | {:file, Path.t()}, String.t()) ::
          Igniter.t()
  def require_present(igniter, check, reason) do
    {present?, what} =
      case check do
        {:dep, name} -> {Igniter.Project.Deps.has_dep?(igniter, name), "the #{name} dependency"}
        {:file, path} -> {Igniter.exists?(igniter, path), path}
      end

    if present?,
      do: igniter,
      else: Igniter.add_warning(igniter, "#{what} is missing, but #{reason}. Add it first.")
  end

  @doc """
  Renders a template file: EEx when it ends in `.eex`, verbatim otherwise.
  """
  @spec render(Path.t(), map()) :: String.t()
  def render(source, assigns) do
    content = File.read!(source)

    if Path.extname(source) == ".eex",
      do: EEx.eval_string(content, [assigns: assigns], file: source),
      else: content
  end

  @doc """
  Replaces `__var__` path variables in `path` with assigns, raising with the
  variable and `template` when one has no assign.
  """
  @spec expand_path(Path.t(), map(), Path.t()) :: Path.t()
  def expand_path(path, assigns, template) do
    Regex.replace(@var, path, fn _match, var ->
      case Enum.find(assigns, fn {key, _value} -> to_string(key) == var end) do
        {_key, value} ->
          to_string(value)

        nil ->
          raise ArgumentError,
                "template #{template} uses the path variable __#{var}__, but there is " <>
                  "no #{var} assign. Available: #{Enum.map_join(Map.keys(assigns), ", ", &to_string/1)}"
      end
    end)
  end

  defp step_dir(name, id) do
    module = Cookbook.module_for(name)

    if Cookbook.cookbook_module?(module),
      do:
        module
        |> Cookbook.from_module()
        |> Cookbook.source_dir()
        |> Path.join("steps/" <> Composer.Step.template_dir(id)),
      else: raise(ArgumentError, "no cookbook named #{inspect(name)} is installed")
  end

  defp merged_assigns(igniter, opts) do
    Map.merge(assigns(igniter), Map.new(Keyword.get(opts, :assigns, %{})))
  end

  defp strip_eex(path), do: String.replace_suffix(path, ".eex", "")

  defp write(igniter, target, content, opts) do
    case Keyword.get(opts, :on_exists, :overwrite) do
      :overwrite ->
        Igniter.create_or_update_file(igniter, target, content, fn source ->
          Rewrite.Source.update(source, :content, content)
        end)

      :skip ->
        Composer.Edit.Files.create_unless_exists(igniter, target, content)
    end
  end

  defp move_to_def(zipper, name, arity) do
    Igniter.Code.Common.move_to(zipper, fn z ->
      case Sourceror.Zipper.node(z) do
        {:def, _, [{:when, _, [{^name, _, args} | _]} | _]} -> length(args || []) == arity
        {:def, _, [{^name, _, args} | _]} -> length(args || []) == arity
        _ -> false
      end
    end)
  end

  defp present?(igniter, path, content) do
    if Igniter.exists?(igniter, path) do
      igniter
      |> Igniter.include_existing_file(path)
      |> Map.fetch!(:rewrite)
      |> Rewrite.source!(path)
      |> Rewrite.Source.get(:content)
      |> String.contains?(content)
    else
      false
    end
  end

  defp insert_at(text, content, :append), do: text <> content

  defp insert_at(text, content, {:after, anchor}) do
    case String.split(text, anchor, parts: 2) do
      [before, rest] -> before <> anchor <> content <> rest
      [_] -> text
    end
  end

  defp insert_at(text, content, {:before, anchor}) do
    case String.split(text, anchor, parts: 2) do
      [before, rest] -> before <> content <> anchor <> rest
      [_] -> text
    end
  end

  defp missing_anchor(:append, path), do: "could not append to #{path}"

  defp missing_anchor({position, anchor}, path) do
    "could not find #{inspect(anchor)} in #{path}, so nothing was inserted #{position} it"
  end
end
