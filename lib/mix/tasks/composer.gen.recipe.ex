defmodule Mix.Tasks.Composer.Gen.Recipe do
  @shortdoc "Adds a recipe to a recipe group"

  @moduledoc """
  Adds a recipe stub to a recipe group, creating the group file when it
  does not exist.

      mix composer.gen.recipe ash/base
      mix composer.gen.recipe lv/auth --local

  adds the recipe `base` to `lib/composer/<app>/recipes/ash.exs` in the
  current project's cookbook, or, with `--local`, `auth` to
  `<config dir>/recipes/lv.exs` in your local recipes (see
  `Composer.Local`). The argument is always `group/name`.

  A new group file starts with a comment listing the entry forms. Adding
  to an existing group appends to its keyword list; a recipe of the same
  name is an error.

  ## Options

    * `--local` - write to the local config directory
    * `-c`, `--config` - the local config directory, with `--local`
  """

  use Igniter.Mix.Task

  alias Composer.Recipe.Group
  alias Mix.Tasks.Composer.Gen.Cookbook, as: GenCookbook

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      positional: [:path],
      schema: [local: :boolean, config: :string],
      aliases: [c: :config],
      example: "mix composer.gen.recipe ash/base --local"
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    arg = igniter.args.positional.path

    {group, name} =
      case String.split(arg, "/") do
        [group, name] ->
          if Group.valid_name?(group) and Group.valid_name?(name),
            do: {group, name},
            else: invalid!(arg)

        _ ->
          invalid!(arg)
      end

    opts = igniter.args.options

    {file, cookbook} =
      if opts[:local] do
        {dir, _how} = Composer.Local.dir(opts[:config])
        {Path.join([dir, "recipes", group <> ".exs"]), "local"}
      else
        cookbook =
          igniter |> Igniter.Project.Application.app_name() |> GenCookbook.cookbook_name()

        {"lib/composer/#{cookbook}/recipes/#{group}.exs", cookbook}
      end

    ref = "#{cookbook}:#{group}/#{name}"

    igniter =
      if Igniter.exists?(igniter, file),
        do: append(igniter, file, name, ref),
        else: Igniter.create_new_file(igniter, file, source(group, name, ref))

    Igniter.add_notice(igniter, """
    Preview and run the recipe with:

        mix composer.recipe.show #{ref}
        mix composer.recipe.run #{ref}
    """)
  end

  defp invalid!(arg) do
    Mix.raise("""
    Invalid recipe #{inspect(arg)}. Give it as group/name (e.g. ash/base): \
    the recipe name in the group file recipes/<group>.exs. Both are \
    lowercase [a-z0-9_] segments.
    """)
  end

  defp append(igniter, file, name, ref) do
    igniter = Igniter.include_existing_file(igniter, file)
    content = igniter.rewrite |> Rewrite.source!(file) |> Rewrite.Source.get(:content)

    case Group.names(content, file) do
      {:ok, names} ->
        if name in names, do: Mix.raise("#{ref} already exists in #{file}.")

        {:__block__, _, [[entry]]} = Sourceror.parse_string!(stub(name))

        Igniter.update_elixir_file(igniter, file, fn zipper ->
          zipper = last_expression(zipper)

          case Igniter.Code.List.append_to_list(zipper, entry) do
            {:ok, zipper} -> {:ok, zipper}
            :error -> {:error, "#{file} does not end in a keyword list of recipes."}
          end
        end)

      {:error, reason} ->
        Mix.raise(Composer.Error.message(reason))
    end
  end

  defp last_expression(zipper) do
    case Sourceror.Zipper.node(zipper) do
      {:__block__, _, [_, _ | _]} ->
        zipper |> Sourceror.Zipper.down() |> Sourceror.Zipper.rightmost()

      _ ->
        zipper
    end
  end

  defp stub(name) do
    """
    [
      #{name}: [
        shortdoc: "TODO: describe this recipe in one line",
        steps: []
      ]
    ]
    """
  end

  defp source(group, name, ref) do
    """
    # Recipe group #{group}. Each recipe here is addressed as
    # #{String.replace_suffix(ref, "/" <> name, "/<name>")}; run one with:
    #
    #     mix composer.recipe.run #{ref}
    #
    # A recipe is a keyword list:
    #
    #   shortdoc: "..."            one line, shown by mix composer.recipe.list
    #   doc: "..."                 longer help, shown by mix composer.recipe.show
    #   flags: [flag: "..."]       every if: :flag used in steps, described
    #   aliases: [lab: "composer_lab"]  short cookbook names for this recipe's refs
    #   steps: [...]               run top to bottom, as one diff
    #
    # Step entries:
    #
    #   "core:setup/credo"             a step ("cookbook:path", or "path")
    #   "hex:oban"                     a Hex package and its own installer
    #   {"core:oban_pro", if: :flag}   only with --flag
    #   {:use, "other"}                another recipe in this group, in place
    #   {:use, "local:tools/dev"}      a recipe in another group or cookbook
    #   {:task, "x.y", ["arg"]}        compose an Igniter-aware Mix task
    #   {:queue, "x.y", ["arg"]}       run a Mix task after changes apply
    #
    # Browse steps with `mix composer.step.list`. This file is evaluated as
    # Elixir code.
    """ <> stub(name)
  end
end
