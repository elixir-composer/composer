defmodule Mix.Tasks.Composer.Init do
  @shortdoc "Generates a project cookbook and default recipe"

  @moduledoc """
  Sets up the current app as a composer cookbook, with a default recipe
  listing every built-in step:

      lib/composer/<app>.ex
      lib/composer/<app>/recipes/app.exs   (the recipe /app/default)
      lib/composer/<app>/steps/             (your own one-off steps)

  The recipe lists every built-in step in a sensible order, each with a
  one-line description pulled from the step itself. It is data, not
  machinery: delete what you don't want, reorder freely, add your own steps.
  Run it with:

      mix composer.recipe.run /app/default

  The cookbook module is guarded with `if Code.ensure_loaded?(Composer)`, so
  the app still compiles where composer, a dev-only dependency, is absent.

  ## Starting from a shared recipe

  Pass `--from` with a recipe reference (from any installed cookbook) to
  copy *that* recipe instead of the built-in cookbook:

      mix composer.init --from cb_lab/lv/base

  The copy becomes `/app/default`. Root (`/...`, `:...`) and relative
  (`./...`) addresses, and cookbook aliases, are written out in full, so
  they still name what they did in the source chapter.
  Comments in the source are not copied. The app owns and can edit its
  copy, while the shared recipe stays the template.

  ## Options

    * `--from REF` - copy this recipe instead of the built-in cookbook
  """

  use Igniter.Mix.Task

  alias Composer.{CLI, Ref, Cookbook}
  alias Mix.Tasks.Composer.Gen.Cookbook, as: GenCookbook

  # The default recipe written into new projects: every built-in step,
  # grouped and ordered, with taste-heavy or license-gated steps behind
  # flags. Descriptions are rendered from each step's summary at generation
  # time, so the file can never drift from the actual cookbook.
  @shortdoc_default "Every built-in step, in a sensible order"

  @sections [
    {"Undo phx.new defaults you don't want",
     [
       "cb_std:phx:remove_agents_md",
       "cb_std:phx:remove_daisy_ui",
       "cb_std:phx:remove_live_title_suffix",
       "cb_std:phx:remove_theme_toggle",
       "cb_std:phx:remove_topbar"
     ]},
    {"Generate configuration and code",
     [
       "cb_std:phx:minimal_app_layout",
       "cb_std:phx:minimal_home_page",
       "cb_std:phx:tailwind_formatter",
       "cb_std:setup:gitignore",
       "cb_std:pg:extensions",
       "cb_std:setup:generator_defaults",
       "cb_std:ecto:base_schema",
       "cb_std:setup:mix_env_config"
     ]},
    {"Add packages",
     [
       "cb_std:phx:bun",
       "cb_std:setup:credo",
       "cb_std:setup:dotenv_parser",
       {"cb_std:setup:exsync", if: :exsync},
       "cb_std:cluster:libcluster",
       "cb_std:pg:vector",
       "cb_std:setup:quokka",
       "cb_std:phx:remixicons",
       "cb_std:ecto:uuidv7",
       {"cb_std:setup:mix_test_watch", if: :mix_test_watch},
       {:comment, "No built-in step: these ship their own installers, which run here."},
       "hex:oban",
       "hex:oban_web",
       "hex:tidewave",
       {:comment,
        "tidewave's own installer only wires the plug — it writes no MCP config, so this follows it in the list to fill that gap."},
       "cb_std:tidewave:tidewave_config",
       {:comment, "Patches what oban's installer wrote, so it follows it in the list."},
       {"cb_std:oban_pro", if: :oban_pro}
     ]},
    {"Deployment",
     [
       {"cb_std:cluster:gigalixir", if: :gigalixir},
       {"cb_std:cluster:gigalixir:libcluster", if: :gigalixir}
     ]},
    {"Tidy mix.exs",
     [
       "cb_std:ecto:force_drop",
       {:comment, "Last, so it also sorts the deps the steps above added"},
       "cb_std:setup:sort_deps"
     ]}
  ]

  @doc false
  # The step references the default recipe uses, for tests.
  def cookbook do
    for {_title, entries} <- @sections, entry <- entries, ref = ref(entry), do: ref
  end

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      schema: [from: :string],
      composes: ["composer.gen.cookbook"],
      example: "mix composer.init --from cb_lab/lv/base"
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    app = Igniter.Project.Application.app_name(igniter)
    name = GenCookbook.cookbook_name(app)
    path = "lib/composer/#{name}/recipes/app.exs"
    opts = igniter.args.options

    source =
      case opts[:from] do
        nil -> cookbook_source()
        from -> from_source(from)
      end

    igniter
    |> Igniter.create_new_file(path, source)
    |> Igniter.compose_task("composer.gen.cookbook", ["--bundled"])
    |> Igniter.add_notice("""
    Your default recipe is /app/default in #{path} — every step is
    documented in place. Edit the list, then run it with:

        mix composer.recipe.run /app/default

    When it finishes, set up the database and start the server:

        mix ecto.setup && mix phx.server

    Browse steps with `mix composer.step.list` and `mix composer.step.show REF`.
    """)
  end

  defp cookbook_source do
    cb_std = Cookbook.from_module(Composer.CbStd)

    steps =
      @sections
      |> Enum.map(fn {title, entries} ->
        "      # #{title}\n\n" <> Enum.map_join(entries, "\n", &render_entry(&1, cb_std))
      end)
      |> Enum.join("\n\n")

    # A flag shared by several steps is described by the first.
    flags =
      for({_title, entries} <- @sections, entry <- entries, flag = flag(entry), do: {flag, entry})
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.map(fn {flag, entry} ->
        "      #{flag}: #{inspect(describe(ref(entry), cb_std))},"
      end)

    """
    # This project's chapter, generated by `mix composer.init`. Each
    # recipe here is addressed as /app/<name>:
    #
    #     mix composer.recipe.run /app/default
    #     mix composer.recipe.run /app/default --oban-pro --gigalixir
    #
    # Steps run top to bottom, and every change is shown as one diff before it
    # is applied. This file is yours: delete steps you don't want, reorder
    # freely, add more recipes. Tag a step with `if: :flag` to make it
    # optional (it then runs only when you pass the matching `--flag`), and
    # describe the flag under flags:.
    #
    #   "cb_std:setup:credo"      a step, as "cookbook:path:to:step"
    #   "hex:oban"                a Hex package and its own installer
    #   "./other"                 another recipe in this chapter, in place
    #   "cb_lab/lv/base"          a recipe in another cookbook
    #   {:task, "x.y", []}        compose any Igniter task
    #
    # Write your own steps with `mix composer.gen.step NAME`, and browse the
    # rest with `mix composer.step.list`. Docs: https://hexdocs.pm/composer
    [
      default: [
        shortdoc: #{inspect(@shortdoc_default)},
        doc: \"\"\"
        Every built-in step, grouped and ordered. Taste-heavy or license-gated
        steps run only with their flag.
        \"\"\",
        flags: [
    #{Enum.join(flags, "\n")}
        ],
        steps: [
    #{steps}
        ]
      ]
    ]
    """
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  defp render_entry({:comment, text}, _core), do: "      # #{text}"

  defp render_entry(entry, cb_std) do
    ref = ref(entry)

    description =
      case flag(entry) do
        nil ->
          describe(ref, cb_std)

        flag ->
          "#{describe(ref, cb_std)} (only with --#{String.replace(to_string(flag), "_", "-")})"
      end

    code =
      case flag(entry) do
        nil -> inspect(ref)
        flag -> "{#{inspect(ref)}, if: #{inspect(flag)}}"
      end

    "      # #{description}\n      #{code},"
  end

  defp ref({:comment, _text}), do: nil
  defp ref({ref, _opts}), do: ref
  defp ref(ref), do: ref

  defp flag({ref, opts}) when is_binary(ref), do: opts[:if]
  defp flag(_entry), do: nil

  defp describe("hex:" <> package, _core) do
    "Installs #{package} and runs the package's own igniter installer"
  end

  defp describe(ref, cb_std) do
    case Cookbook.step(cb_std, Ref.path(Ref.parse!(ref))) do
      {:ok, meta} -> meta.summary || ref
      :error -> raise "the default recipe references unknown step: #{ref}"
    end
  end

  defp from_source(from) do
    cookbooks = CLI.cookbooks!()
    id = CLI.ok!(Composer.Resolver.find_recipe(cookbooks, from, CLI.context(cookbooks)))
    %Ref{cookbook: name, segments: segments} = ref = Ref.parse!(id)
    cookbook = Enum.find(cookbooks, &(&1.name == name))
    path = Ref.path(ref)

    recipe =
      CLI.ok!(
        Composer.Recipe.load(Cookbook.recipe_path(cookbook, path), name, List.last(segments))
      )

    steps = Enum.map(recipe.steps, &qualify(&1, recipe, cookbooks))

    fields =
      [shortdoc: recipe.shortdoc, doc: recipe.doc, flags: recipe.flags, steps: steps]
      |> Enum.reject(fn {key, value} -> value in [nil, []] and key != :steps end)

    body =
      [default: fields]
      |> inspect(pretty: true, limit: :infinity, printable_limit: :infinity)
      |> Code.format_string!()
      |> IO.iodata_to_binary()

    """
    # Copied from #{id} (#{recipe.path}) by `mix composer.init --from #{from}`.
    # Edits here do not affect the shared recipe. Run it with:
    #
    #     mix composer.recipe.run /app/default
    """ <> body <> "\n"
  end

  # Root and relative addresses, and aliases, are resolved where the
  # source recipe lives, so the copy still names the same recipes and steps.
  defp qualify({ref, opts}, recipe, cookbooks) when is_binary(ref),
    do: {qualified(ref, recipe, cookbooks), opts}

  defp qualify(ref, recipe, cookbooks) when is_binary(ref), do: qualified(ref, recipe, cookbooks)
  defp qualify(entry, _recipe, _cookbooks), do: entry

  defp qualified(ref, recipe, cookbooks) do
    case Composer.Resolver.address_id(cookbooks, recipe, ref) do
      {:ok, id} -> id
      {:error, _} -> ref
    end
  end
end
