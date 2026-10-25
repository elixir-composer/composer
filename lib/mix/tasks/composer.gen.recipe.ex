defmodule Mix.Tasks.Composer.Gen.Recipe do
  @shortdoc "Adds a recipe to a chapter"

  @moduledoc """
  Adds a recipe stub to a chapter, creating the chapter file when it
  does not exist.

      mix composer.gen.recipe ash/base
      mix composer.gen.recipe ash/ui/tailwind/base

  adds the recipe `base` to `lib/composer/<app>/recipes/ash.exs` (or
  `recipes/ash/ui/tailwind.exs`) in the current project's cookbook. The
  argument is `chapter/name`, where the chapter may be a nested path; the
  root address `/ash/base` is accepted too. The recipe is then addressed
  as `<app>/ash/base`, or `/ash/base` from inside the cookbook.

  A new chapter file starts with a comment listing the entry forms. Adding
  to an existing chapter appends to its keyword list; a recipe of the same
  name is an error.
  """

  use Igniter.Mix.Task

  alias Composer.Recipe.Chapter
  alias Mix.Tasks.Composer.Gen.Cookbook, as: GenCookbook

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      positional: [:path],
      example: "mix composer.gen.recipe ash/base"
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    arg = igniter.args.positional.path
    path = arg |> String.trim() |> String.trim_leading("/") |> String.replace("-", "_")

    {chapter, name} =
      case {Path.dirname(path), Path.basename(path)} do
        {"." <> _, _name} ->
          invalid!(arg)

        {chapter, name} ->
          if Chapter.valid_path?(chapter) and Chapter.valid_name?(name),
            do: {chapter, name},
            else: invalid!(arg)
      end

    cookbook = igniter |> Igniter.Project.Application.app_name() |> GenCookbook.cookbook_name()
    file = "lib/composer/#{cookbook}/recipes/#{chapter}.exs"
    ref = Composer.Ref.id(:recipe, cookbook, path)

    igniter =
      if Igniter.exists?(igniter, file),
        do: append(igniter, file, name, ref),
        else: Igniter.create_new_file(igniter, file, source(chapter, name, ref))

    Igniter.add_notice(igniter, """
    Preview and run the recipe with:

        mix composer.recipe.show #{ref}
        mix composer.recipe.run #{ref}
    """)
  end

  defp invalid!(arg) do
    Mix.raise("""
    Invalid recipe #{inspect(arg)}. Give it as chapter/name (e.g. ash/base, \
    or ash/ui/base for a nested chapter): the recipe name in the chapter \
    file recipes/<chapter>.exs. Every segment is lowercase [a-z0-9_].
    """)
  end

  defp append(igniter, file, name, ref) do
    igniter = Igniter.include_existing_file(igniter, file)
    content = igniter.rewrite |> Rewrite.source!(file) |> Rewrite.Source.get(:content)

    case Chapter.names(content, file) do
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

  defp source(chapter, name, ref) do
    """
    # Chapter #{chapter}. Each recipe here is addressed as
    # #{String.replace_suffix(ref, "/" <> name, "/<name>")}; run one with:
    #
    #     mix composer.recipe.run #{ref}
    #
    # A recipe is a keyword list:
    #
    #   shortdoc: "..."            one line, shown by mix composer.recipe.list
    #   doc: "..."                 longer help, shown by mix composer.recipe.show
    #   flags: [flag: "..."]       every if: :flag used in steps, described
    #   aliases: [lab: "cc_lab"]   short cookbook names for this recipe's addresses
    #   steps: [...]               run top to bottom, as one diff
    #
    # Step entries:
    #
    #   "cb_std:setup:credo"            a step (":path:to:step" in this cookbook)
    #   "hex:oban"                      a Hex package and its own installer
    #   {"cb_std:oban_pro", if: :flag}  only with --flag
    #   "./other"                       another recipe in this chapter, in place
    #   "/chapter/name"                 a recipe in another chapter of this cookbook
    #   "cb_lab/lv/base"                a recipe in another cookbook
    #   {:task, "x.y", ["arg"]}         compose an Igniter-aware Mix task
    #   {:queue, "x.y", ["arg"]}        run a Mix task after changes apply
    #
    # Browse steps with `mix composer.step.list`. This file is evaluated as
    # Elixir code.
    """ <> stub(name)
  end
end
