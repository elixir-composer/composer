# Recipes

A **recipe** is a named, ordered, flag-aware list of steps, with its own
docs. Recipes live in **chapters**: one `.exs` file holding one or more
recipes, keyed by name.

```elixir
# recipes/phx.exs
[
  clean: [
    shortdoc: "Strip the Phoenix theme toggle and topbar",
    steps: ["cb_std:phx/remove_theme_toggle", "cb_std:phx/remove_topbar"]
  ],
  app: [
    shortdoc: "A Phoenix app with my usual tooling",
    doc: """
    Builds on phx/clean. Pass --oban-pro for Oban Pro, --gigalixir to
    deploy there.
    """,
    flags: [
      oban_pro: "Add Oban Pro",
      gigalixir: "Deploy to Gigalixir"
    ],
    steps: [
      {:use, "clean"},
      "cb_std:setup/credo",
      "cb_std:setup/quokka",
      "hex:oban",
      {"cb_std:oban_pro", if: :oban_pro},
      {:use, "my_app:deploy/gigalixir", if: :gigalixir},
      {:task, "ash.codegen", ["initial"]},
      "cb_std:setup/sort_deps"
    ]
  ]
]
```

The terms:

  * A **recipe** has a name, a shortdoc, an optional doc, optional flags
    and a list of steps.
  * A **chapter** is one file under `recipes/`. The file name is the chapter
    name, so the file above holds `phx/clean` and `phx/app`.
  * A **cookbook** is a package that ships steps (with their templates) and recipe
    chapters.

## Addressing

Every recipe lives in a chapter and is addressed as
`<cookbook>:<chapter>/<name>`:

    recipes/<chapter>.exs  →  <cookbook>:<chapter>/<name>

so `recipes/phx.exs` in the cookbook `my_app` holds `my_app:phx/clean` and
`my_app:phx/app`. Give chapters logical names (`ash.exs`, `lv.exs`) rather
than a catch-all `recipes.exs`. Moving a recipe to another chapter changes
its address, the same as moving a step.

## Recipe keys

| Key                   | Meaning                                                      |
|-----------------------|--------------------------------------------------------------|
| `shortdoc` (required) | one line, shown by `mix composer.recipe.list`                |
| `doc`                 | longer help, shown by `mix composer.recipe.show`             |
| `flags`               | `[flag: "description"]`, shown by `mix composer.recipe.show` |
| `aliases`             | `[lab: "cc_lab"]`, short cookbook names (see below)    |
| `steps` (required)    | the entries below                                            |

Every `if: :flag` in a recipe's own steps must be declared in its own
`flags`; a flag declared only by a recipe it `:use`s does not count.

## Where chapters live

  * **In a cookbook**, at `lib/composer/<package>/recipes/<chapter>.exs`.
    Your app's own `app/default` recipe, written by `mix composer.init`, is
    one.
  * **In a personal cookbook**, a small cookbook package of your own,
    added to each app as a path dependency. It holds the recipes you reuse
    across apps, and any personal steps and templates. See
    [Personal cookbook](cookbooks.md#personal-cookbook).

A chapter has the same relative path, file format and addressing rule
in every cookbook. Chapters are files: a subdirectory under `recipes/` is
not a chapter. Add a recipe to a chapter (creating the file if needed) with:

```bash
mix composer.gen.recipe ash/base                  # in this project's cookbook
```

> **Chapter files are Elixir code**, evaluated with `Code.eval_file/1`. Only
> use recipes you wrote or trust.

A chapter file must end in a **literal** keyword list (`[name: [...], ...]`)
so its recipe names can be listed, and completed, without evaluating it.
Bindings before the list are fine, and the values can be any expression.

## Entries

| Entry                                        | Meaning                                                        |
|----------------------------------------------|----------------------------------------------------------------|
| `"cb_std:setup/credo"`                         | a step, by `"cookbook:path"`                                   |
| `"setup/credo"`                              | a step, unqualified (see below)                                |
| `"hex:oban"`                                 | a Hex package: added to `mix.exs`, then its own installer runs |
| `"hex:org.pkg"`                              | a package from a private Hex repo or organization              |
| `"hex:ash@3.5"`, `"hex:x@path:../x"`         | a package from a version or source (see [Hex packages](#hex-packages)) |
| `{"hex:ash_authentication", argv: ["--auth-strategy", "password"]}` | a package whose installer runs with arguments |
| `{"hex:mix_test_watch", only: [:dev, :test], runtime: false}` | a package with dependency options |
| `{"hex:my_lib", path: "../my_lib"}`          | a package from a source: `version:`, `github:`, `git:` or `path:` |
| `{"cb_std:oban_pro", if: :oban_pro}`           | a step that runs only with `--oban-pro`                        |
| `{"cc_lab:x", argv: ["--all"]}`              | a step run with options, as after `--` on `composer.step.run`  |
| `{:use, "clean"}`                            | the recipe `clean` in the same chapter, in place                 |
| `{:use, "cb_lab:lv/base"}`                   | a recipe in another chapter or cookbook                          |
| `{:use, "deploy/gigalixir", if: :gigalixir}` | ... only with `--gigalixir`                                    |
| `{:task, "x.y", ["arg"]}`                    | compose any Igniter-aware Mix task                             |
| `{:queue, "x.y", ["arg"]}`                   | run a Mix task after the changes apply                         |

A step's `argv:` and `if:` combine: `{"cc_lab:x", argv: ["--all"], if: :x}`.
On a `hex:` entry, `argv:` goes to the package's installer (`mix
<pkg>.install`), which always runs with `--yes` added. A package that
ships no installer has nowhere to send `argv:`, so the run warns.
`{:task, ...}` and `{:queue, ...}` take an `if:` keyword as a fourth
element. Queued tasks run non-interactively with `--yes` appended; use them
only for work that must see the applied project on disk.

## Hex packages

`"hex:pkg"` adds a package to `mix.exs` and runs its own Igniter
installer, if it ships one. Every package in a run is added first and
fetched and compiled **once**, then each installer runs at its position in
the step list, so its changes land in the run's single diff. The prefix
stays `hex:` whatever the source: it means "a dependency whose own
installer runs", and Hex is the default source.

The keyword form is the one to use in recipes, because it is validated
option by option:

```elixir
steps: [
  "hex:ash",
  {"hex:ash", version: "~> 3.5"},
  {"hex:ash_authentication", argv: ["--auth-strategy", "password"]},
  {"hex:mix_test_watch", only: [:dev, :test], runtime: false},
  {"hex:live_debugger", github: "software-mansion/live-debugger", only: :dev},
  {"hex:x", git: "https://example.com/x.git", tag: "v1.0.0"},
  {"hex:my_lib", path: "../my_lib"}
]
```

| Option                        | Meaning                                                      |
|-------------------------------|--------------------------------------------------------------|
| `argv: ["--opt", "v"]`        | arguments for the package's installer                        |
| `only: :dev` / `[:dev, :test]`| the dependency's `only:`                                     |
| `runtime: false`              | the dependency's `runtime:`                                  |
| `version: "~> 3.5"`           | a version requirement instead of the latest Hex release      |
| `github: "owner/repo"`        | a GitHub dependency                                          |
| `git: url`                    | a git dependency                                             |
| `path: "../my_lib"`           | a local dependency, written with `override: true`            |
| `ref:` / `branch:` / `tag:`   | with `github:` or `git:`, at most one of them                |
| `sparse: "dir"`, `submodules: true` | with `github:` or `git:`                               |

An entry takes at most one source. Without one, the latest Hex version is
looked up. A private-repo package (`hex:org.pkg`) takes `version:` only.
If the package is already in `mix.exs`, its declaration is replaced, as
`mix igniter.install` does.

Set `only:` yourself when you want it: Composer adds the dependency
itself, so an installer's own preference (`live_debugger` declares
`only: [:dev]`) is not applied, and `tidewave` declares none.

### The `@` shorthand

For the command line, and for people used to `mix igniter.install`, a
`hex:` reference can carry its source after an `@`:

| Reference                          | Same as                                      |
|------------------------------------|----------------------------------------------|
| `hex:ash@3.5.0`                    | `version: "== 3.5.0"`                        |
| `hex:ash@3.5`                      | `version: "~> 3.0"` (Igniter's rule)         |
| `hex:ash@~>3.5`                    | `version: "~>3.5"`, kept as written          |
| `hex:ash@github:ash-project/ash`   | `github: "ash-project/ash"`                  |
| `hex:ash@github:ash-project/ash@main` | ... plus `ref: "main"`                    |
| `hex:x@git:git@github.com:a/x.git` | `git: "git@github.com:a/x.git"`              |
| `hex:my_lib@path:../my_lib`        | `path: "../my_lib"`                          |

The reference is split on its first `@`, so the source can hold `:`, `@`
and `-`; only the package name is normalized (`live-debugger` is
`live_debugger`). An `@` source and a keyword source on one entry are an
error, and so is an `@` on anything but `hex:`.

```bash
mix composer.step.run hex:my_lib@path:../my_lib
mix composer.step.run hex:ash_authentication -- --auth-strategy password
```

On the command line, arguments after `--` go to the installer. References
are split on `,`, so a source containing a comma needs a recipe entry.

### Duplicates and conflicts

The same package with the same options, reached through any number of
includes, runs once (`only: :dev` and `only: [:dev]` are the same). The
same package with **different** options — argv, source or dependency
options, or options in one place and none in another — is an error naming
every recipe involved, even when the entries sit behind different `if:`
flags: both flags can be on at once, and a run adds one dependency per
package. Give each entry the same options, or keep one.

`requires: ["hex:pkg"]` in a step matches an install of `pkg` by name,
whatever its source or options. Plan output shows each install's source
and argv:

```console
Composer plan
  hex:my_lib (path ../my_lib) — dependency only, ships no installer
  hex:ash_authentication --auth-strategy password — ash_authentication.install
```

### When to write a step instead

Write a step only when the package ships **no installer**, or when you
need **more than its installer** does. A step that only adds a package
and runs its installer duplicates `hex:` and costs a deps fetch and
compile of its own; use a `hex:` entry with `argv:`, dependency options or
a source instead. To patch what an installer wrote, list your step after
the `hex:` entry.

## Resolving references

`"cookbook:path"` is exact. An unqualified step `"path"`:

  1. is looked up first in the recipe's own cookbook (on the command line,
     the current project's cookbook);
  2. then in every cookbook. One match resolves to it; more than one is an
     error listing every candidate, so qualify the reference;
  3. matching nothing, is the Hex package of that name — `"oban"` is
     `"hex:oban"` — unless it is very close to a step id, which is reported
     as a likely typo.

A step in a cookbook wins over a Hex package of the same name.

`{:use, "name"}` without a `/` is the recipe of that name **in the same
chapter**; nothing outside the chapter can match it. `{:use, "chapter/name"}`
resolves like an unqualified step (own cookbook first, then every
cookbook), with no Hex fallback.

## Cookbook aliases

Cookbook names equal their package's OTP app, so qualified references can
be long: `cc_lab:auth/passkeys`. A recipe can declare short names
for the cookbooks it refers to:

```elixir
passkeys: [
  shortdoc: "Passkey sign-in",
  aliases: [lab: "cc_lab"],
  steps: ["lab:auth/passkeys", {:use, "lab:auth/base"}]
]
```

`lab:auth/passkeys` then resolves exactly as `cc_lab:auth/passkeys`.
An alias is only a lookup shortcut; it never renames a cookbook:

  * it applies to the declaring recipe's own step and `{:use, ...}`
    references only — **not** inside a recipe it includes (that recipe
    uses its own aliases), and never to references typed on the command
    line;
  * its value is a string naming a package cookbook. `cb_std`, `hex`,
    `local` (and other reserved names) cannot be targets, and an atom
    value is rejected;
  * its name is a lowercase `[a-z0-9_]` name other than `cb_std`, `hex` and
    `local`, declared once per recipe, and it must not be the name of an
    installed cookbook — pick alias names that don't look like package
    names, since a cookbook installed later would collide;
  * listings, `--json` and run commits show the real cookbook name;
    `recipe.show` marks an aliased step with `(as lab)`, and errors quote
    the reference as written: `lab:auth/passkeys (lab = cc_lab):
    cookbook cc_lab not found`.

To share aliases across a chapter, bind them before the final list (the
file must still end in a literal keyword list):

```elixir
# recipes/auth.exs
aliases = [lab: "cc_lab"]

[
  passkeys: [shortdoc: "Passkey sign-in", aliases: aliases, steps: ["lab:auth/passkeys"]],
  magic: [shortdoc: "Magic-link sign-in", aliases: aliases, steps: ["lab:auth/magic_link"]]
]
```

## Composition rules

  * **Include-once.** A recipe is expanded at most once per run; later
    includes of it are no-ops. A diamond is not a cycle.
  * **No cycles.** A cycle is an error that prints the whole chain, across
    chapters and cookbooks: `my_app:ash/a -> cc_lab:lv/b -> my_app:ash/a`.
  * **De-duplication.** A step equal to an earlier one is dropped, first
    occurrence wins — `"setup/credo"` and `"cb_std:setup/credo"` count as the
    same step.
    Steps that differ only in their `if:` are distinct. Keep finishing steps
    like `"cb_std:setup/sort_deps"` in a recipe that is used last.
  * **Flags** declared by the recipe, and by every recipe it reaches,
    become `--flag` options of `mix composer.recipe.run`. Any other
    `--flag` is rejected.

## Listing, showing and running

```bash
mix composer.recipe.list                         # every cookbook, in discovery order
mix composer.recipe.list my_app                  # one cookbook
mix composer.recipe.list my_app cb_lab           # several (separate arguments)
mix composer.recipe.list my_app:phx/             # one chapter (note the slash)
mix composer.recipe.show my_app:phx/app          # docs, flags, resolved steps
mix composer.recipe.edit my_app:phx/app          # open its chapter file in your editor
mix composer.recipe.run my_app:phx/app --oban-pro
mix composer.recipe.run my_app:phx/app --dry-run
```

`recipe.show` follows every gated include, so it shows everything the
recipe can run, and warns about phase order, overlapping `provides`,
`conflicts`, and required steps that aren't listed earlier.

`recipe.run` resolves every reference and checks every step's `requires`
before anything runs, applies the steps as one diff without asking, and
records the run as one git commit listing every step and the recipe it
came from. It refuses to start outside a git work tree or in a dirty one;
`--no-commit` skips the git checks and the commit.

`recipe.edit` opens the recipe's chapter file at the recipe's line, with
the command in `COMPOSER_EDITOR` (then `VISUAL`, then `EDITOR`).
`__FILE__` and `__LINE__` in it are replaced, as in `ELIXIR_EDITOR`:

```bash
export COMPOSER_EDITOR="nvim +__LINE__ __FILE__"                 # this terminal
export COMPOSER_EDITOR="ghostty -e nvim -c __LINE__ __FILE__"   # a new window
```

Pass `--print` to print `path:line` instead.

## Checking recipes

```bash
mix composer.cookbook.lint             # this project's cookbook, recipes included
mix composer.cookbook.lint --format compact --file lib/composer/my_app/recipes/ash.exs
```

To see problems in your editor as you save a chapter file, see the
[lint guide](lint.md).

Lint reports a subdirectory under `recipes/`, a chapter file that is not
a keyword list of recipes, a duplicate recipe name, a missing `shortdoc`
or `steps`, an unknown key, an undeclared `if:` flag, an invalid,
reserved, duplicate or shadowing alias, a recipe named like a chapter, and
every recipe that does not resolve. It warns about an alias that none of
the recipe's references use, and about an alias that names different
cookbooks in two recipes of one chapter.

## Starting a new app from a recipe

```bash
mix composer.init --from cb_lab:lv/base
```

copies the recipe into the new app as `app/default`, so the app owns and
can edit its setup while the shared recipe stays the template. Same-chapter
`{:use, ...}` entries are qualified so they still resolve; comments are not
copied.

## Migrating from one recipe per file

Recipes used to be one file each, with help text in a leading `#`
comment. That format is gone, and loading such a file is an error pointing
at the chapter format. Convert by hand: gather related files into one chapter,
key each recipe by its old name, move the comment into `shortdoc:`, and
point `{:use, "my_app:old_name"}` at the new address (or at `{:use,
"name"}` within the same chapter).

```elixir
# before: recipes/ash_base.exs and recipes/ash_ecto.exs
# Ash with the Postgres data layer.
[{:use, "my_app:ash_base"}, "cc_lab:ash/postgres"]

# after: recipes/ash.exs
[
  base: [shortdoc: "Ash core", steps: ["cc_lab:ash"]],
  ecto: [
    shortdoc: "Ash with the Postgres data layer",
    steps: [{:use, "base"}, "cc_lab:ash/postgres"]
  ]
]
```
