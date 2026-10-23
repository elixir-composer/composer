# Elixir Composer

Composer is an app generation tool for Elixir.

Elixir package maintainers ship
[generators](https://hexdocs.pm/phoenix/Mix.Tasks.Phx.New.html) and
[igniters](https://github.com/ash-project/igniter) — indispensable tools. And
yet, turning a generated skeleton into a working prototype can still be a lot
of work. You need to know which defaults to remove, which packages to add, how
to configure them, and a dozen other things. That knowledge is scattered across
blog posts, READMEs, conference talks and developers' heads. Composer aims to
capture this scattered tacit knowledge into an organized cookbook that is
**repeatable, composable and sharable**.

Composer builds on generators and Igniter to produce a skeleton that is better
suited to its purpose from the start, so you reach a first working prototype
sooner. Composer manages changes like:

- removing generator defaults you don't want
- injecting layouts and styles
- adding pages and navigation
- creating seed data
- configuring add-on packages: auth, mailers, API extensions, and more

Composer is inspired by the `installer` feature on
[AshHQ](https://ash-hq.org/installer/). It extends that idea so that cookbooks
are easy to:

- bundle with any Elixir framework (eg Phoenix, Ash, Jido, Mob, TermUI, Astral...)
- write and tweak, for every developer (not just package maintainers)
- share between teams
- search and discover, by humans and agents

Composer is also inspired by dev-ops tools like Chef, Puppet, Ansible and Salt.
Before them, configuring a server was a manual craft, built on the tacit
knowledge of Ops engineers, arcane bash scripts and obscure configuration
spells. Devops tools encoded that know-how as code, in cookbooks of repeatable,
composable recipes, and turned provisioning into a reliable scalable process.
Setting up a new application is still a manual craft. Composer applies the same
approach: setup know-how lives in shared cookbooks, and every new app starts
from proven recipes instead of from scratch.

## Overview

### Concepts

With composer, a cookbook contains recipes; recipes are lists of steps, organized in groups;
steps make changes and can render templates.

- A **step** is an atomic/composable Igniter task.  For search and discovery,
  steps also contain metadata: a summary, facets such as `action: :remove` or
  `frameworks: [:phoenix]`, tags, and what it `requires`. Addressed as
  `"cookbook:step"`.
- A **recipe** is a named, ordered list of steps, with a shortdoc, optional
  doc and flags. Recipes live in **groups**, one `.exs` file per group, and
  are addressed as `"cookbook:group/name"`.
- A **cookbook** is a self-contained collection of steps (with their
  templates) and recipes, shipped by a framework, a standalone package, or your own app.
  Composer ships a built-in `core` cookbook; your personal recipes live in
  a cookbook of your own, added to apps as a path dependency.

### Mix tasks

| Task                                      | Purpose                                          |
|-------------------------------------------|--------------------------------------------------|
| `composer.init`                           | Make your app a cookbook and generate its recipe |
| `composer.recipe.{list,show,run,edit}`    | List, inspect, run and edit recipes              |
| `composer.step.{list,find,help,run,edit}` | List, search, inspect, run and edit steps        |
| `composer.cookbook.list`                  | List discovered cookbooks                        |
| `composer.gen.{step,recipe,cookbook}`     | Scaffold a step, recipe or cookbook              |
| `composer.cookbook.{manifest,lint}`       | Write a cookbook's manifest; lint it             |
| `composer.completion`, `composer.index`   | Shell completion                                 |
| `composer.lsp`                            | Language server for recipe files                 |

### Recipes

A recipe is plain data. `mix composer.init` generates one; edit it to taste:

```elixir
# lib/composer/my_app/recipes/app.exs
[
  default: [
    shortdoc: "My app's setup",
    flags: [oban: "Add Oban"],
    steps: [
      "core:phx/remove_daisy_ui",                # undo a phx.new default
      "core:phx/remove_topbar",
      "core:setup/gitignore",                    # project hygiene
      "core:setup/credo",                        # add a package
      {"cc_lab:ash/postgres", argv: ["--all"]},  # a step with arguments
      "hex:ash",                                 # a Hex package's own installer
      {"hex:oban", if: :oban},                   # optional, behind --oban
      "my_app:deploy_config",                    # your own step
      {:use, "cb_mine:dev/tools"}                # include another recipe
    ]
  ]
]
```

It runs as one diff, with the flags it declares:

```console
$ mix composer.recipe.run app/default --oban
```

## Getting started

### 1. Create an app and add the dependency

```bash
mix igniter.new my_app --with phx.new
cd my_app
```

Add `composer` to your deps in `mix.exs`:

```elixir
def deps do
  [
    {:composer, "~> 0.2.1", only: :dev},
    # ...
  ]
end
```

```bash
mix deps.get
```

### 2. Generate your recipe

```bash
mix composer.init
```

This makes your app a cookbook and writes
**`lib/composer/my_app/recipes/app.exs`**, holding the recipe
`app/default`: every built-in step in a sensible order, each with a one-line
description. Open it (`mix composer.recipe.edit app/default`) and make it
yours:

- **Delete** any step you don't want — the file is yours.
- **Reorder** steps freely; they run top to bottom.
- **Tag** a step with `if: :flag` to make it optional — it then only runs
  when you pass the matching `--flag`. Describe the flag under `flags:`.

### 3. Run it

```bash
mix composer.recipe.show app/default     # preview: docs, flags, resolved steps, warnings
mix composer.recipe.run app/default
```

Nothing is applied blindly. Every reference is resolved and every step's
`requires` checked before anything runs. The run prints a plan showing what
each step resolved to, then applies all changes — your steps and package
installers together — as one diff, recorded as one git commit (a dirty work
tree is refused). Pass `--dry-run` to preview the diff, `--no-commit` to skip
the commit.

Only dependencies come first: packages that ship an installer are added to
`mix.exs` and fetched up front, since their installers must be on disk to
run. When the run finishes, set up the database and go:

```bash
mix ecto.setup
mix phx.server
```

> **Note:** the generated recipe enables the `vector` Postgres extension via
> the `pg/extensions` and `pg/vector` steps. If your local Postgres doesn't
> have [pgvector](https://github.com/pgvector/pgvector) installed, either
> install it or delete those two steps from your recipe.

Keep the recipe in your repo: it documents exactly how your app was set
up, and you'll copy it into your next project.

### Running single steps

Every step also works on its own, no recipe required:

```bash
mix composer.step.run core:setup/credo,core:setup/quokka
mix composer.step.run phx/remove_daisy_ui    # unqualified names work too
mix composer.step.run hex:oban               # a package's own installer
mix composer.step.run hex:ash@github:ash-project/ash   # ... from GitHub
mix composer.step.run hex:my_lib@path:../my_lib        # ... from a local path
mix composer.step.run cc_lab:foo -- --bar   # arguments after -- go to the step
mix composer.step.run hex:ash_authentication -- --auth-strategy password  # ... or the installer
```

### Finding steps

```bash
mix composer.cookbook.list                   # cookbooks, with step and recipe counts
mix composer.step.list --action remove       # also --cookbook, --framework, --tag
mix composer.step.find tailwind
mix composer.step.show core:phx/bun          # facets, requires, and a dry run
mix composer.step.edit core:phx/bun          # open its source in your editor
mix composer.recipe.list
```

Every listing task takes `--json`, for scripts and agents.

### Scripts and CI

Runs are interactive by default (diff, then confirm), except
`composer.recipe.run`, which always applies unattended. In a script or CI,
pass Igniter's standard `--yes` flag to auto-accept:

```bash
mix composer.init --yes && mix composer.recipe.run default --no-commit
```

## Why not just…

- **`mix igniter.new --install a,b,c`?** Great for installing packages that
  ship installers, and Composer runs those same installers rather than
  competing with them. Composer is for everything around that: *removing*
  `phx.new` defaults (nothing else does this), packages that don't ship
  installers, ordering steps, optional flags, and keeping the whole ritual
  versioned in your repo.
- **A boilerplate/template repo?** Templates fork away from `phx.new` and
  rot. A recipe replays your preferences on top of whatever `phx.new`
  currently generates.

## References and Hex packages

An unqualified name is looked up in the referring recipe's own cookbook
first, then in every cookbook. If it matches nothing, it is a Hex package:
`"oban"` means `"hex:oban"` — add the package and run its own installer.
Which of the two applies is upstream's business, and each run prints a plan
telling you which it was:

```console
Composer plan
  core:setup/credo
  hex:oban — oban.install
  hex:nimble_options — dependency only, ships no installer
  core:setup/sort_deps
```

A name that matches steps in two cookbooks is an error that lists both, and
a name that looks like a typo of a step is reported rather than looked up on
Hex. Qualify the reference (`"core:setup/credo"`) to be exact.

A `hex:` entry can pass arguments to the installer, set dependency options,
and install from a version, GitHub, git or a local path:

```elixir
{"hex:ash_authentication", argv: ["--auth-strategy", "password"]},
{"hex:mix_test_watch", only: [:dev, :test], runtime: false},
{"hex:live_debugger", github: "software-mansion/live-debugger", only: :dev},
{"hex:my_lib", path: "../my_lib"},
"hex:ash@3.5"                                  # the @ shorthand, as in mix igniter.install
```

All packages in a run still share one deps fetch and compile, and the plan
shows each one's source and arguments
(`hex:my_lib (path ../my_lib)`). See
[Hex packages](guides/recipes.md#hex-packages).

Composer deliberately ships **no step for packages that provide their own
Igniter installer** — `oban`, `tidewave`, `ash` and friends run upstream's
installer, so upstream stays the authority. Built-in steps exist only where
upstream ships nothing, and each does the minimum wiring the package's
installer would do if it existed.

## Built-in steps

All built-in steps live in the `core` cookbook, grouped by directory
(`phx/`, `setup/`, `ecto/`, `pg/`, `cluster/`, `tidewave/`): reference them
as `"core:<id>"`, e.g. `"core:setup/credo"`. `mix composer.step.list
--cookbook core` lists them with their facets.

| Id                             | Action | What it does                                                                                                                               |
|--------------------------------|--------|--------------------------------------------------------------------------------------------------------------------------------------------|
| `phx/bun`                      | add    | Replaces esbuild/tailwind with Bun: dep, package.json, config, watchers, aliases, tsconfig                                                 |
| `phx/minimal_app_layout`       | patch  | Replaces `Layouts.app/1` with a minimal header/main layout                                                                                 |
| `phx/minimal_home_page`        | patch  | Replaces the `phx.new` marketing page with a minimal home page                                                                             |
| `phx/remixicons`               | add    | Remix Icons as a Tailwind plugin with `remix-*` classes and a CoreComponents `icon` clause                                                 |
| `phx/remove_agents_md`         | remove | Removes the generated `AGENTS.md`                                                                                                          |
| `phx/remove_daisy_ui`          | remove | Removes the `:daisyui` Mix dependency and CSS plugin blocks                                                                                |
| `phx/remove_live_title_suffix` | remove | Removes the `" · Phoenix Framework"` title suffix                                                                                          |
| `phx/remove_theme_toggle`      | remove | Removes the theme scripts, component, and usage                                                                                            |
| `phx/remove_topbar`            | remove | Removes the topbar progress indicator                                                                                                      |
| `phx/tailwind_formatter`       | gen    | HEEx formatter that sorts Tailwind classes                                                                                                 |
| `setup/credo`                  | add    | Dev/test dependency for static analysis                                                                                                    |
| `setup/dotenv_parser`          | add    | Loads `.env` in runtime config; creates and gitignores `.env`                                                                              |
| `setup/exsync`                 | add    | Auto-recompilation on file changes (dev)                                                                                                   |
| `setup/generator_defaults`     | config | Generators default to `binary_id` + `utc_datetime_usec`                                                                                    |
| `setup/gitignore`              | config | Adds the expert cache (`.expert/`) to `.gitignore`                                                                                         |
| `setup/mix_env_config`         | config | `config :app, env: Mix.env()` for runtime environment checks                                                                               |
| `setup/mix_test_watch`         | add    | Runs tests on file changes                                                                                                                 |
| `setup/quokka`                 | add    | Credo-configured formatter plugin                                                                                                          |
| `setup/sort_deps`              | patch  | Sorts `mix.exs` dependencies alphabetically                                                                                                |
| `ecto/base_schema`             | gen    | `MyApp.Schema` module with sensible key/timestamp defaults                                                                                 |
| `ecto/force_drop`              | config | `ecto.drop --force-drop` in the mix alias                                                                                                  |
| `ecto/uuidv7`                  | add    | Time-sortable UUID primary keys; updates your `Schema` module when present                                                                 |
| `pg/extensions`                | gen    | Migration enabling citext, pg_trgm, unaccent, and vector                                                                                   |
| `pg/vector`                    | add    | Vector search: dep, Postgrex types, config, extension migration (merges into existing extensions migration)                                |
| `cluster/gigalixir`            | gen    | Gigalixir deploy: buildpacks, Procfile, release migration scripts, SSL config                                                              |
| `cluster/gigalixir/libcluster` | config | Kubernetes clustering strategy for Gigalixir                                                                                               |
| `cluster/libcluster`           | add    | Node clustering: dep, supervision child, Gossip topology in dev                                                                            |
| `tidewave/tidewave_config`     | add    | Creates `.mcp.json` pointing at a local Tidewave MCP server (follows `hex:tidewave`)                                                       |
| `oban_pro`                     | add    | Oban Pro 1.8: Pro engine, Cron/Lifeline/Pruner/Queues services, migration (requires a license and an Oban 2.24+ setup; follows `hex:oban`) |
| `echo`                         | debug  | Prints a message to stdout; changes nothing (for debugging recipes)                                                                        |

Steps that pattern-match against `phx.new` output warn loudly when they find
nothing to change, instead of silently no-oping.

## Writing your own steps

Your app is a cookbook too, so a one-off step lives next to your recipe:

```bash
mix composer.gen.step deploy_config
```

writes `lib/composer/my_app/steps/deploy_config.ex`, with every facet
stubbed out, and a test:

```elixir
defmodule Composer.MyApp.Steps.DeployConfig do
  use Composer.Step,
    summary: "Writes the deploy config",
    action: :gen,
    capability: [:deploy],
    stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Igniter.create_new_file(igniter, "config/deploy.exs", "# ...")
  end
end
```

Reference it as `"my_app:deploy_config"` (or just `"deploy_config"` from your
own recipes). `Composer.Templates`, `Composer.Helpers` and
`Composer.Versions` provide conveniences for common patterns: rendering
template files, app/repo module names, checked file edits, migration
timestamps and latest-version lookups.

## Sharing steps and recipes

Steps and recipes travel in **cookbook packages**: a Hex package with a
`lib/composer/<package>/` tree. Add one as a dev dependency and its steps
and recipes appear in every listing task, referenced as
`"<package>:<path>"`. Scaffold one with:

```bash
mix composer.gen.cookbook
mix composer.gen.step ash/postgres
mix composer.gen.recipe lv/base
mix composer.cookbook.manifest      # commit the manifest
mix composer.cookbook.lint          # in CI (--format github for annotations)
```

See the [cookbooks guide](guides/cookbooks.md) for the layout, naming
rules and bundling a cookbook with a framework.

Your personal recipes live in a cookbook of your own (`cb_mine` here): an
ordinary Mix project in git, added to each app as a path dependency. See
[Personal cookbook](guides/cookbooks.md#personal-cookbook) for setting
one up.

```bash
mix igniter.install cb_mine@path:../cb_mine --only dev,test
mix composer.recipe.list cb_mine              # every recipe in it, with its shortdoc
mix composer.recipe.run cb_mine:dev/tools
mix composer.init --from cb_lab:lv/base       # start a new app from a shared recipe
```

Lint reports every problem at its place in the file, and speaks the
formats editors and CI read (`--format compact|json|github`, `--file` for
on-save checks in Vim, Neovim, VS Code and others); see the
[lint guide](guides/lint.md).

For editing recipes, `mix composer.lsp` runs `composer-ls`, a language
server beside your Elixir one: warm diagnostics on save (also in the files
that include the saved recipe), hover, goto-definition, completion of step
and recipe ids, and quick fixes. See the
[Composer LSP guide](guides/composer_lsp.md).

A step entry can carry options: `{"cc_lab:x", argv: ["--all"]}` passes
arguments to the step, as `--` does on `mix composer.step.run`, and combines
with `if:` (`{"cc_lab:x", argv: ["--all"], if: :x}`). On a `hex:`
entry, `argv:` goes to the package's installer.

Recipes compose: `{:use, "cb_mine:dev/tools"}` includes another recipe's
steps in place, to any depth, optionally behind a flag (`{:use,
"deploy/gigalixir", if: :gigalixir}`); `{:use, "base"}` names a recipe in
the same group. At run time the tree is flattened into one ordered step
list — packages from the whole tree are deduped and fetched up front, a
single diff covers the entire run, and flags declared anywhere in the tree
surface on the task you invoke (any other `--flag` is rejected). See the
[recipes guide](guides/recipes.md).

Steps apply in list order, package installers included, so a step that
patches what an installer wrote just goes after it:

```elixir
"hex:oban",
"my_team:oban_tweaks"
```

`{:queue, "some.task", []}` is there for work that genuinely has to run
against the applied project on disk, after everything else.

## Shell completion

```bash
mix composer.completion bash > ~/.local/share/bash-completion/completions/mix-composer
```

Completion of step and recipe ids reads a plain-text index under
`_build/composer/`, so it never starts the BEAM. Every composer task keeps
the index fresh; `mix composer.index` rebuilds it.

## License

MIT — see [LICENSE.md](LICENSE.md).
