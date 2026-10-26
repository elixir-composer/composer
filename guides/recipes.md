# Recipes

A **recipe** is a named, ordered, flag-aware list of steps, with its own
docs. Recipes live in **chapters**: one `.exs` file holding one or more
recipes, keyed by name.

```elixir
# recipes/phx.exs
[
  clean: [
    shortdoc: "Strip the Phoenix theme toggle and topbar",
    steps: ["cb_std:phx:remove_theme_toggle", "cb_std:phx:remove_topbar"]
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
      "./clean",
      "cb_std:setup:credo",
      "cb_std:setup:quokka",
      "hex:oban",
      {"cb_std:oban_pro", if: :oban_pro},
      {"/deploy/gigalixir", if: :gigalixir},
      {:task, "ash.codegen", ["initial"]},
      "cb_std:setup:sort_deps"
    ]
  ]
]
```

The terms:

  * A **recipe** has a name, a shortdoc, an optional doc, optional flags
    and a list of steps.
  * A **chapter** is one file under `recipes/`, possibly in a
    subdirectory. Its path under `recipes/` is the chapter path, so the
    file above holds `phx/clean` and `phx/app`.
  * A **cookbook** is a package that ships steps (with their templates) and recipe
    chapters.

## Addressing

Every address says its **kind** and its **scope**. The separator gives
the kind: `/` for a recipe, `:` for a step. The first character gives the
scope:

| Scope         | Recipe                         | Step                                  |
|---------------|--------------------------------|---------------------------------------|
| Qualified     | `my_app/ash/ui/buttons`        | `cb_std:cluster:gigalixir:libcluster` |
| Cookbook root | `/ash/ui/buttons`              | `:cluster:gigalixir:libcluster`       |
| Relative      | `./base`, `../buttons`         | (reserved, not supported yet)         |
| Package       |                                | `hex:oban@3.5`, `hex:oban.oban_pro`   |
| Search        | `buttons` (command line only)  | `libcluster` (command line only)      |

A recipe's address is its cookbook, its chapter path and its name:

    recipes/<chapter path>.exs  →  <cookbook>/<chapter path>/<name>

so `recipes/phx.exs` in the cookbook `my_app` holds `my_app/phx/clean` and
`my_app/phx/app`, and `recipes/ash/ui/tailwind.exs` holds
`my_app/ash/ui/tailwind/<name>`. The last segment is always the recipe's
name and the rest its chapter path, so `recipes/ash/ui.exs` and the
directory `recipes/ash/ui/` can live side by side. A recipe address has at
least a chapter and a name: `my_app/base` is an error.

A step's address is its cookbook and its path under `steps/`, with `:`:
`steps/cluster/gigalixir/libcluster.ex` in `cb_std` is
`cb_std:cluster:gigalixir:libcluster`.

  * **Qualified** addresses name their cookbook (or one of the recipe's
    [aliases](#cookbook-aliases)).
  * **Root** addresses (`/ash/base`, `:setup:thing`) are in the recipe's
    own cookbook; on the command line, in the current project's cookbook.
  * **Relative** addresses are recipes relative to the recipe's chapter,
    and always stay in its cookbook. From `recipes/ash/ui/tailwind.exs`:

    | Written          | Is                             |
    |------------------|--------------------------------|
    | `./base`         | `ash/ui/tailwind/base`         |
    | `./forms/inputs` | `ash/ui/tailwind/forms/inputs` |
    | `../buttons`     | `ash/ui/buttons`               |
    | `../../core`     | `ash/core`                     |
    | `../../../core`  | an error: no chapter for core  |

  * A **bare name** is a search, for the one recipe or step, in any
    cookbook, whose last segment it is. It works on the command line only
    (`mix composer.step.run credo`); in a recipe it is an error, so
    installing another cookbook can never change what a recipe means.

Names are lowercase `[a-z0-9_]`; `-` is read as `_`. Give chapters
logical names (`ash.exs`, `lv.exs`, `ash/ui.exs`) rather than a catch-all
`recipes.exs`. Moving a recipe to another chapter changes its address, the
same as moving a step.

## Recipe keys

| Key                   | Meaning                                                      |
|-----------------------|--------------------------------------------------------------|
| `shortdoc` (required) | one line, shown by `mix composer.recipe.list`                |
| `doc`                 | longer help, shown by `mix composer.recipe.show`             |
| `flags`               | `[flag: "description"]`, shown by `mix composer.recipe.show` |
| `aliases`             | `[lab: "cc_lab"]`, short cookbook names (see below)          |
| `steps` (required)    | the entries below                                            |

Every `if: :flag` in a recipe's own steps must be declared in its own
`flags`; a flag declared only by a recipe it includes does not count.

## Where chapters live

  * **In a cookbook**, at `lib/composer/<package>/recipes/**/<chapter>.exs`.
    Your app's own `/app/default` recipe, written by `mix composer.init`,
    is one.
  * **In a personal cookbook**, a small cookbook package of your own,
    added to each app as a path dependency. It holds the recipes you reuse
    across apps, and any personal steps and templates. See
    [Personal cookbook](cookbooks.md#personal-cookbook).

A chapter has the same relative path, file format and addressing rule
in every cookbook. Chapters may be nested in directories under `recipes/`;
every directory and file name is a lowercase `[a-z0-9_]` name. Add a
recipe to a chapter (creating the file if needed), or create an empty
top-level chapter, with:

```bash
mix composer.gen.recipe ash/base                  # in this project's cookbook
mix composer.gen.recipe ash/ui/tailwind/base      # a nested chapter
mix composer.gen.recipe ash                       # an empty chapter
```

> **Chapter files are Elixir code**, evaluated with `Code.eval_file/1`. Only
> use recipes you wrote or trust.

A chapter file must end in a **literal** keyword list (`[name: [...], ...]`)
so its recipe names can be listed, and completed, without evaluating it.
Bindings before the list are fine, and the values can be any expression.

## Entries

An entry's kind comes from its address: a recipe address includes that
recipe in place, a step address (`hex:` included) is a step.

| Entry                                        | Meaning                                                        |
|----------------------------------------------|----------------------------------------------------------------|
| `"cb_std:setup:credo"`                       | a step in another cookbook                                     |
| `":setup:thing"`                             | a step in this recipe's own cookbook                           |
| `"hex:oban"`                                 | a Hex package: added to `mix.exs`, then its own installer runs |
| `"hex:org.pkg"`                              | a package from a private Hex repo or organization              |
| `"hex:ash@3.5"`, `"hex:x@path:../x"`         | a package from a version or source (see [Hex packages](#hex-packages)) |
| `{"hex:ash_authentication", argv: ["--auth-strategy", "password"]}` | a package whose installer runs with arguments |
| `{"hex:mix_test_watch", only: [:dev, :test], runtime: false}` | a package with dependency options |
| `{"hex:my_lib", path: "../my_lib"}`          | a package from a source: `version:`, `github:`, `git:` or `path:` |
| `{"cb_std:oban_pro", if: :oban_pro}`         | a step that runs only with `--oban-pro`                        |
| `{"cc_lab:x", argv: ["--all"]}`              | a step run with options, as after `--` on `composer.step.run`  |
| `"./clean"`                                  | the recipe `clean` in the same chapter, in place               |
| `"../ui/buttons"`, `"/deploy/gigalixir"`     | a recipe elsewhere in this cookbook                            |
| `"cb_lab/lv/base"`                           | a recipe in another cookbook                                   |
| `{"/deploy/gigalixir", if: :gigalixir}`      | ... only with `--gigalixir`                                    |
| `{:task, "x.y", ["arg"]}`                    | compose any Igniter-aware Mix task                             |
| `{:queue, "x.y", ["arg"]}`                   | run a Mix task after the changes apply                         |

A step's `argv:` and `if:` combine: `{"cc_lab:x", argv: ["--all"], if: :x}`.
A recipe include takes only `if:`; any other option is an error.
On a `hex:` entry, `argv:` goes to the package's installer (`mix
<pkg>.install`), which always runs with `--yes` added. A package that
ships no installer has nowhere to send `argv:`, so the run warns.
`{:task, ...}` and `{:queue, ...}` take an `if:` keyword as a fourth
element. Queued tasks run non-interactively with `--yes` appended; use them
only for work that must see the applied project on disk.

A bare word (`"oban"`) is not an address: write `"hex:oban"`, or the
step's full address. The error says which: `"credo" is not an address;
did you mean "cb_std:setup:credo"?`. `{:use, ...}` is gone; it is an error
naming the include to write instead.

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
`hex:` address can carry its source after an `@`:

| Address                            | Same as                                      |
|------------------------------------|----------------------------------------------|
| `hex:ash@3.5.0`                    | `version: "== 3.5.0"`                        |
| `hex:ash@3.5`                      | `version: "~> 3.0"` (Igniter's rule)         |
| `hex:ash@~>3.5`                    | `version: "~>3.5"`, kept as written          |
| `hex:ash@github:ash-project/ash`   | `github: "ash-project/ash"`                  |
| `hex:ash@github:ash-project/ash@main` | ... plus `ref: "main"`                    |
| `hex:x@git:git@github.com:a/x.git` | `git: "git@github.com:a/x.git"`              |
| `hex:my_lib@path:../my_lib`        | `path: "../my_lib"`                          |

The address is split on its first `@`, so the source can hold `:`, `@`
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

## Resolving addresses

Resolution depends only on the address and where it is written:

  * a **qualified** address is looked up exactly, after its cookbook part
    is checked against the recipe's aliases. An unknown cookbook is an
    error that suggests adding the package that ships it;
  * a **root** address is looked up in the recipe's own cookbook, and on
    the command line in the current project's cookbook (an error when the
    project is not a cookbook);
  * a **relative** address is looked up from the recipe's chapter (an
    error on the command line, which has no chapter);
  * a **search**, on the command line only, finds the one recipe or step
    whose last segment matches; several matches are an error listing
    them, and a match of the other kind (a step for `recipe.run`) says so.
    There is no Hex fallback: write `hex:oban`.

A missing address whose other-kind twin exists says so: `no recipe
cb_std/echo; did you mean the step cb_std:echo?`. Typo and "moved into a
group" suggestions name the close addresses.

## Cookbook aliases

Cookbook names equal their package's OTP app, so qualified addresses can
be long: `cc_lab:auth:passkeys`. A recipe can declare short names
for the cookbooks it refers to:

```elixir
passkeys: [
  shortdoc: "Passkey sign-in",
  aliases: [lab: "cc_lab"],
  steps: ["lab:auth:passkeys", "lab/auth/base"]
]
```

`lab:auth:passkeys` then resolves exactly as `cc_lab:auth:passkeys`, and
`lab/auth/base` as `cc_lab/auth/base`.
An alias is only a lookup shortcut; it never renames a cookbook:

  * it applies to the declaring recipe's own qualified addresses only —
    never to root or relative ones (they have no cookbook part), **not**
    inside a recipe it includes (that recipe uses its own aliases), and
    never to addresses typed on the command line;
  * its value is a string naming a package cookbook. `cb_std`, `hex`,
    `local` (and other reserved names) cannot be targets, and an atom
    value is rejected;
  * its name is a lowercase `[a-z0-9_]` name other than `cb_std`, `hex` and
    `local`, declared once per recipe, and it must not be the name of an
    installed cookbook — pick alias names that don't look like package
    names, since a cookbook installed later would collide;
  * listings, `--json` and run commits show the real cookbook name;
    `recipe.show` marks an aliased step with `(as lab)`, and errors quote
    the address as written: `lab:auth:passkeys (lab = cc_lab):
    cookbook cc_lab not found`.

To share aliases across a chapter, bind them before the final list (the
file must still end in a literal keyword list):

```elixir
# recipes/auth.exs
aliases = [lab: "cc_lab"]

[
  passkeys: [shortdoc: "Passkey sign-in", aliases: aliases, steps: ["lab:auth:passkeys"]],
  magic: [shortdoc: "Magic-link sign-in", aliases: aliases, steps: ["lab:auth:magic_link"]]
]
```

## Composition rules

  * **Include-once.** A recipe is expanded at most once per run; later
    includes of it are no-ops. A diamond is not a cycle.
  * **No cycles.** A cycle is an error that prints the whole chain, across
    chapters and cookbooks: `my_app/ash/a -> cc_lab/lv/b -> my_app/ash/a`.
  * **De-duplication.** A step equal to an earlier one is dropped, first
    occurrence wins — `":setup:credo"` in a `cb_std` recipe and
    `"cb_std:setup:credo"` count as the same step.
    Steps that differ only in their `if:` are distinct. Keep finishing steps
    like `"cb_std:setup:sort_deps"` in a recipe that is used last.
  * **Flags** declared by the recipe, and by every recipe it reaches,
    become `--flag` options of `mix composer.recipe.run`. Any other
    `--flag` is rejected.

## Listing, showing and running

```bash
mix composer.recipe.list                         # every cookbook, in discovery order
mix composer.recipe.list my_app                  # one cookbook
mix composer.recipe.list my_app cb_lab           # several (separate arguments)
mix composer.recipe.list my_app/phx/             # a chapter, and those nested in it
mix composer.recipe.list /ash/                   # a chapter of this project's cookbook
mix composer.recipe.show my_app/phx/app          # docs, flags, resolved steps
mix composer.recipe.edit /phx/app                # open its chapter file in your editor
mix composer.recipe.run my_app/phx/app --oban-pro
mix composer.recipe.run app --dry-run            # search: the one recipe named app
```

`recipe.show` follows every gated include, so it shows everything the
recipe can run, and warns about phase order, overlapping `provides`,
`conflicts`, and required steps that aren't listed earlier.

`recipe.run` resolves every address and checks every step's `requires`
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

Lint reports a chapter file or directory with an invalid name, an empty
chapter, a chapter file that is not a keyword list of recipes, a duplicate
recipe name, a missing `shortdoc` or `steps`, an unknown key, an
undeclared `if:` flag, an invalid, reserved, duplicate or shadowing alias,
and every address and recipe that does not resolve. It warns about an
alias that none of the recipe's addresses use, about an alias that names
different cookbooks in two recipes of one chapter, and about old-syntax
addresses shown in a `shortdoc:` or `doc:`.

## Starting a new app from a recipe

```bash
mix composer.init --from cb_lab/lv/base
```

copies the recipe into the new app as `/app/default`, so the app owns and
can edit its setup while the shared recipe stays the template. Root and
relative addresses, and aliases, are written out in full so they still
resolve; comments are not copied.

## Migrating to the current address syntax

Older recipes wrote `"cookbook:chapter/name"`, searched for unqualified
names, fell back to Hex, and included recipes with `{:use, ...}`. All of
that is gone. Rewrite a cookbook with:

```bash
mix composer.cookbook.lint --fix
```

which rewrites, in place, every address that has one rewrite, in the
chapter files and in the step modules' `requires:`, keeping comments and
layout:

| Old                       | New                                                         |
|---------------------------|-------------------------------------------------------------|
| `{:use, "name"}`          | `"./name"`                                                  |
| `{:use, "x:a/b"}`         | `"x/a/b"`                                                   |
| `{:use, "a/b"}`           | `"/a/b"` if this cookbook has it, else the one `x/a/b`      |
| `{:use, r, opts}`         | `{new(r), opts}`                                            |
| `"x:a/b/c"` (step)        | `"x:a:b:c"`                                                 |
| `"a/b"` (step)            | `":a:b"` if this cookbook has it, else the one `x:a:b`      |
| `"name"` (step)           | as above, else `"hex:name"`                                 |

Unqualified old addresses are read as they resolved before, against the
cookbooks installed now, so run it with the project's usual dependencies.
What could mean several things is reported, not guessed, and so are
old-syntax addresses in `shortdoc:` and `doc:` text, which you update by
hand.

## Migrating from one recipe per file

Recipes used to be one file each, with help text in a leading `#`
comment. That format is gone, and loading such a file is an error pointing
at the chapter format. Convert by hand: gather related files into one chapter,
key each recipe by its old name, move the comment into `shortdoc:`, and
point includes of the old files at the new address (`"./name"` within
the same chapter).

```elixir
# after: recipes/ash.exs, from recipes/ash_base.exs and recipes/ash_ecto.exs
[
  base: [shortdoc: "Ash core", steps: ["cc_lab:ash"]],
  ecto: [
    shortdoc: "Ash with the Postgres data layer",
    steps: ["./base", "cc_lab:ash:postgres"]
  ]
]
```
