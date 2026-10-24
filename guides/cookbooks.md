# Cookbooks

A **cookbook** is one package's tree of steps and recipes. A cookbook
contains recipes; recipes are lists of steps, filed in chapters; steps render
templates, which live beside them. Every cookbook has the same layout:

```
lib/composer/cc_lab.ex                    # the cookbook module
lib/composer/cc_lab/
  steps/                                        # step modules
    ash.ex                                      #   cc_lab:ash
    ash/postgres.ex                             #   cc_lab:ash/postgres
    astral/nav1.ex                              #   cc_lab:astral/nav1
    astral/_nav1/navbar.astral                  #   its template: template("navbar.astral")
  recipes/                                      # chapters
    lv.exs                                      #   cc_lab:lv/base, cc_lab:lv/auth, ...
  manifest.exs                                  # written by mix composer.cookbook.manifest
test/composer/cc_lab/steps/
  ash_test.exs                                  # one test per step
  ash/postgres_test.exs
```

`lib/composer/` signals at a glance that a package ships a cookbook, and
keeps it apart from the package's own `lib/<package>/` code. A step, its
templates and the recipes that use it sit in one tree.

Scaffold a cookbook with:

```bash
mix composer.gen.cookbook
mix composer.gen.step ash/postgres
mix composer.gen.recipe lv/base
```

## The cookbook module

```elixir
defmodule Composer.CcLab do
  use Composer.Cookbook,
    summary: "Andy's composer steps",
    homepage: "https://github.com/andyl/cc_lab"
end
```

### Naming

**The cookbook name equals the package's OTP app name.** `Composer.CcLab`
is the cookbook `cc_lab`, and it must live in the `:cc_lab` package, in
`lib/composer/cc_lab.ex`. So a package has exactly one cookbook, and Hex's
package-name uniqueness keeps cookbook names unique. A mismatch is a compile
error that says how to fix it.

The one exception is composer itself, whose built-in cookbook is `cb_std`.

Cookbook packages are usually named `composer_<x>`, which makes qualified
references long (`cc_lab:auth/passkeys`). Recipes can declare short
cookbook aliases (`aliases: [lab: "cc_lab"]`) for their own
references; see "Cookbook aliases" in the recipes guide. An alias never
changes the cookbook's name.

These names are reserved, and a cookbook using one fails to compile:

  * `cb_std` (outside composer), `hex` and `local`
  * every top-level `Composer.*` module name: `runner`, `step`, `cookbook`,
    `templates`, `helpers`, `versions`, `resolver`, `ref`, `recipe`,
    `discovery`, `manifest`, `index`, `completion`, `facets`,
    `error`, `git`, `cli`, `preflight` and `lint`

### Discovery

Discovery is a convention lookup: for each dependency, composer checks
whether `Composer.<App>` is loaded and defines a cookbook. Nothing is
scanned, and no configuration is needed. The current project's own cookbook
and composer's `cb_std` are always included. Cookbooks are listed in
discovery order: `cb_std`, the current project's, then each dependency's.

The host app can limit package cookbooks:

```elixir
# config/config.exs
config :composer, cookbooks: [except: [:some_cookbook]]
```

`mix composer.cookbook.list` shows what was found.

## Steps

A step is a module that uses `Composer.Step`:

```elixir
defmodule Composer.CcLab.Steps.Ash.Postgres do
  use Composer.Step,
    summary: "Adds AshPostgres with a Postgres data layer",
    action: :add,
    frameworks: [:ash, :ecto],
    capability: [:database],
    phase: :setup,
    stability: :stable,
    tags: [:postgres],
    requires: ["cc_lab:ash", {:executable, "psql"}],
    provides: [:datalayer]

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    # ...
  end
end
```

The step's id is its path under `steps/`, and the module name must match it
(`steps/ash/postgres.ex` is `Composer.CcLab.Steps.Ash.Postgres`), or the
module fails to compile. Steps are Igniter tasks, so they compose into one
diff, but they are not Mix tasks, so they never appear in `mix help`.

`mix composer.step.edit ash/postgres` opens a step's source file at its
`use Composer.Step` line, with the same editor command as
`mix composer.recipe.edit` (`COMPOSER_EDITOR`, then `VISUAL`, then
`EDITOR`; see the [recipes guide](recipes.md)). Pass `--print` to print
`path:line` instead.

### When to group by path

Use `/` to group steps that belong together: `ash/postgres`, `ash/sqlite`,
`ash/admin` read better and list together, and leave room for more. Use a
flat name for a step that stands alone (`deploy_config`). Don't encode
the action in a group: `remove/topbar` is better written as
`remove_topbar` with `action: :remove`, since the action is a facet.

### Facets

Facets describe a step instead of its module path. The controlled
vocabulary (see `Composer.Facets`):

| Facet        | Values                                                                                                       |
|--------------|--------------------------------------------------------------------------------------------------------------|
| `action`     | `add`, `remove`, `gen`, `config`, `patch`, `debug`                                                           |
| `frameworks` | `phoenix`, `liveview`, `ash`, `astral`, `term_ui`, `mob`, `jido`, `ecto`                                     |
| `capability` | `auth`, `jobs`, `deploy`, `css`, `testing`, `devtools`, `ai`, `observability`, `database`, `assets`, `icons` |
| `phase`      | `cleanup`, `setup`, `generate`, `finalize` (advisory)                                                        |
| `stability`  | `experimental`, `beta`, `stable`, `deprecated`                                                               |

An unknown value is a compile-time warning, never an error, so a cookbook
can run ahead of composer's vocabulary. Use free `tags` for anything else.

`phase` is advisory: list order still decides execution order, but
`mix composer.recipe.show` warns when a later-phase step runs before an
earlier-phase one.

`requires` is checked before a run: a missing executable or an incompatible
version of a package the app has stops the run, and a required step that
isn't listed earlier is a warning. `requires: ["hex:pkg"]` names a package
installed by a `hex:` entry, matched by name whatever its source. `provides` and `conflicts` let composer
warn when a recipe pulls in two steps for the same capability (two CSS
frameworks, say). Use `stability: :experimental` for steps that aren't
ready yet.

### When not to write a step

Don't write a step that only adds a package and runs its Igniter
installer: a recipe's `hex:` entry does exactly that, with installer
arguments, dependency options (`only:`, `runtime:`) and a source
(`version:`, `github:`, `git:`, `path:`), and every `hex:` entry in a run
shares one deps fetch and compile. Write a step only when the package
ships no installer, or when you need more than its installer does — and
then declare `requires: ["hex:pkg"]` and list the step after the `hex:`
entry. See [Hex packages](recipes.md#hex-packages).

## Recipes

Chapters are the `.exs` files directly under `recipes/`; each holds
one or more recipes, addressed as `<cookbook>:<chapter>/<name>`. See the
[recipes guide](recipes.md). Inside a cookbook, unqualified references in
a recipe resolve to the cookbook's own steps and recipes first, and an
unqualified `{:use, "name"}` is the recipe `name` in the same chapter. A
chapter file with an invalid name (`lv-base.exs`) or that does not parse is a
compile error.

## Templates

A step's templates live in the directory named after its file with a
leading underscore (`steps/astral/_nav1/` for `steps/astral/nav1.ex`), so
they never mix with child steps in `steps/astral/nav1/`. They are written into
apps with `Composer.Templates`. There is no cookbook-level `templates/`
directory. See the [templates guide](templates.md).

Every `.ex` file under `steps/` is a step, so Elixir source templates must
be named `.ex.eex`: a bare `.ex` file that is not a step is a compile error
that names the file to rename. (The Elixir compiler may report the bare
file's own errors first; the cookbook's error follows.)

Hex packages ship only the files listed in `package: [files: ...]` in
`mix.exs`. The default, and `~w(lib ...)`, includes templates under
`lib/composer/<name>/steps/`; if you narrow `files`, keep them.

## The manifest

`mix composer.cookbook.manifest` writes `manifest.exs`: plain data with the
cookbook's name, package, and every step's id, summary and facets, and every
recipe's id (`chapter/name`) and shortdoc. Tools such as shell completion read it without
running your code. Commit it; it is never written at compile time, and
`mix composer.cookbook.lint` fails when it is stale.

## Lint

`mix composer.cookbook.lint` checks the current project's cookbook, and
exits non-zero on failure so it can run in CI:

  * every step has a summary, an `action` and a `stability`
  * every step has a test at `test/composer/<cookbook>/steps/<id>_test.exs`
  * every step reference in `requires` resolves
  * the manifest is up to date
  * every chapter is well formed: a keyword list of recipes with a
    one-line `shortdoc`, `steps`, no unknown keys, no duplicate names, every
    `if:` flag declared, no reserved flag name, no subdirectory under
    `recipes/`, and no recipe named like a chapter
  * every recipe resolves
  * there is no cookbook-level `templates/` directory, every file under
    `steps/` belongs to a step, every `.ex` file there is a step, and every
    `template/1` path exists

It warns about a template file that no `template/1` call refers to (steps
whose path is computed at run time are not checked), and about a path
dependency in a project with a `package:` section (see "Publishing a
cookbook" below).

`mix composer.cookbook.lint --file PATH` checks one chapter file of any
installed cookbook, which is what an editor runs on save. Every problem is reported at its file, line and column;
`--format github` turns them into pull request annotations. See the
[lint guide](lint.md) for the formats, the diagnostic codes and editor
setups.

## Personal cookbook

Recipes you reuse across apps (your usual Phoenix setup, your dev
tooling) belong in a cookbook of your own: an ordinary Mix project that
you keep in git and add to each app as a path dependency. Composer treats
it like any other cookbook. Call it what you like; `cb_mine` here.

```bash
mix new cb_mine
cd cb_mine
# add {:composer, path: "../composer"} (or a hex version) to deps, then:
mix deps.get
mix composer.gen.cookbook
rm lib/composer/cb_mine/recipes/app.exs   # the generated sample recipe
```

Add your chapters under `lib/composer/cb_mine/recipes/` (or with
`mix composer.gen.recipe lv/base`), then refresh the manifest and lint:

```bash
mix composer.cookbook.manifest
mix composer.cookbook.lint
```

List every cookbook your recipes refer to as a dependency, **without
`only:`**:

```elixir
defp deps do
  [
    {:composer, path: "../composer"},
    {:cb_lab, path: "../cb_lab"}
  ]
end
```

The cookbook is compiled wherever it is used, and its cross-cookbook
references (`cb_lab:lv/base`) need those cookbooks at lint and run time.
Mix leaves a dependency's own `only:` dependencies out of the app that
uses it, so with `only: :dev` an app installing `cb_mine` would not get
`cb_lab`, and every `cb_lab:` reference would name an unknown cookbook.
An unqualified `chapter/name` in your chapters resolves against your own
cookbook first.

Install it into an app as a dev and test dependency:

```bash
mix igniter.install cb_mine@path:../cb_mine --only dev,test
mix composer.recipe.run cb_mine:lv/base
```

Keep the cookbook in git and sync it between machines with `git pull`;
every app that has it as a path dependency sees the change on its next
run.

When an app also gets one of your cookbook's dependencies from Hex (say
`cb_lab`), Mix sees two sources for it. Mark the app's own dependency with
`override: true`:

```elixir
{:cb_lab, "~> 0.1", only: [:dev, :test], override: true}
```

## Publishing a cookbook

A cookbook installed from Hex or git, for example with
`mix composer.new my_app cb_mine:lv/base@github:me/cb_mine`, must declare
Hex or git dependencies, not path dependencies. Mix resolves a path
relative to the cookbook, which is now a checkout in the app's `deps/`, so
`path: "../composer"` points at nothing. `mix composer.cookbook.lint`
warns about every path dependency in a project that has a `package:`
section.

Some flag names are reserved: a recipe can't declare `no_commit`, one of
Igniter's global switches (`yes`, `dry_run`, `only`, ...), or an option of
`mix composer.new` (`with`, `with_args`, `install`, `composer`,
`extra_dep`, `igniter_local`, `reset`, `no_recipe`) or `recipe`.
`mix composer.new` passes every other switch to the recipe, so a flag
with one of those names could never reach it. Lint reports them.

## Bundling a cookbook with a framework

A framework can ship a cookbook alongside its own code, with composer as an
optional dependency:

```elixir
{:composer, "~> 0.0.1", optional: true, only: :dev}
```

```bash
mix composer.gen.cookbook --bundled
```

`--bundled` wraps the cookbook module (and every step `mix composer.gen.step`
writes later) in `if Code.ensure_loaded?(Composer) do ... end`, so the tree
compiles to nothing — and costs nothing — where composer is absent. An app
whose composer dependency is dev-only needs the same guard, which is why
`mix composer.init` writes it.

## Files your tools will see

Chapter files are `.exs` files under `lib/`, so editors, Credo and
the formatter see them. That is harmless: they are plain keyword lists of
data.
Template files are copied verbatim. `.eex` files are not formatter
inputs, but a verbatim `.exs` template would be; no step is an `.exs`
file, so exclude those under `steps/`:

```elixir
# .formatter.exs
templates = Path.wildcard("lib/composer/*/steps/**/*.exs", match_dot: true)

[inputs: Path.wildcard("{mix,.formatter}.exs") ++ (Path.wildcard("{config,lib,test}/**/*.{ex,exs}") -- templates)]
```

Composer is a development tool: cookbooks are read from the dependency's
source tree, so running composer from a release is not supported.
