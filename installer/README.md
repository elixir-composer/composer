# composer_new

`mix composer.new` creates an Elixir app and applies a
[composer](https://github.com/elixir-composer/composer) recipe to it, in
one command:

```bash
mix composer.new my_app --recipe cb_std/completions/install \
  --with phx.new --with-args=--no-ecto
```

It drives `igniter.new` and Igniter's installer; it doesn't replace them.

## Install

```bash
mix archive.install hex igniter_new     # 0.5.32 or later
mix archive.install hex composer_new
mix archive.install hex phx_new         # only for --with phx.new
```

`composer_new` and `composer` have the same version, and an app created
by `composer_new` X.Y.Z gets `composer ~> X.Y` unless `--composer` says
otherwise.

`igniter_new` must be 0.5.32 or later: earlier releases either ignore
`--no-git` or pass it on to the installers of `--install` packages. Upgrade
with `mix archive.install hex igniter_new --force`.

## Usage

```
mix composer.new APP [--cookbook PKG]... [--recipe REF [--recipe-args ARGS]] [OPTIONS]
```

APP comes first, as with `igniter.new` and `phx.new`, and is the only
positional argument. It may have a directory part (`/tmp/my_app`); its
last segment must be a valid app name. Everything else is a named option,
so a script reads as what it does:

```bash
mix composer.new my_app \
  --cookbook cb_lab@github:elixir-composer/cb_lab \
  --recipe cb_lab/phx/saas \
  --recipe-args="--oban-pro --gigalixir" \
  --with phx.new --with-args=--no-ecto
```

### Cookbooks

```
--cookbook PKG[@SOURCE]
SOURCE = <requirement>                 hex, kept as written: @~> 0.3, @>= 0.3.1
       | <version>                     hex: @0.3.1 is == 0.3.1, @0.3 is ~> 0.3 (no @: the latest)
       | github:OWNER/REPO[@GITREF]
       | git:URL
       | path:PATH
```

Each `--cookbook` is installed as a dev/test dep, with its own deps;
repeat it for more than one. `cb_std` ships with composer, so it is never
given here.

### Recipe

```
--recipe COOKBOOK/CHAPTER/RECIPE
--recipe-args ARGS
```

`--recipe` is the one recipe to run, a qualified address: a root
(`/lv/base`), relative (`./base`) or bare (`base`) address is an error, as
are step addresses (`cb_lab:lv:x`) and `hex:` addresses. A recipe takes no
`@SOURCE`; its cookbook is:

1. `cb_std`, which ships with composer; or
2. the `--cookbook` of that name; or else
3. the latest Hex release of that name. If Hex has no such package,
   preflight fails before anything is created.

If the cookbook has no such recipe, `mix composer.recipe.run` says so, and
the app is left at its generation commit.

`--recipe-args` are the recipe's flags, as one string split the way a
shell would (`--recipe-args="--title 'My App' --oban-pro"`), and go to
`mix composer.recipe.run`, which rejects any flag the recipe doesn't
declare before it changes anything. It needs `--recipe`.

```bash
# from Hex: --recipe alone names the cookbook
mix composer.new my_app --recipe cb_lab/lv/base
# github, default branch or pinned
mix composer.new my_app --cookbook cb_lab@github:elixir-composer/cb_lab --recipe cb_lab/lv/base
mix composer.new my_app --cookbook cb_lab@github:elixir-composer/cb_lab@v0.3.0 \
  --recipe cb_lab/lv/base
# a local checkout
mix composer.new my_app --cookbook cb_home@path:~/src/Gen/cb_home \
  --recipe cb_home/lv/base --with phx.new
# a base that is a package, not a task
mix composer.new my_blog --cookbook cb_home@path:~/src/Gen/cb_home \
  --recipe cb_home/astral/min --install astral@path:~/src/Fork/astral
# two cookbooks, and recipe flags
mix composer.new my_app --cookbook cb_mine@path:../cb_mine --cookbook cb_lab \
  --recipe cb_mine/phx/saas --recipe-args="--oban-pro --gigalixir"
```

Without `--recipe`, the app gets composer and the `--cookbook`s, and no
recipe runs. Without either, run `mix composer.init` in it to start the
app's own cookbook.

### Options

| Option                 | Meaning                                                                       |
|------------------------|-------------------------------------------------------------------------------|
| `--cookbook PKG`       | a cookbook, installed as a dev/test dep (repeatable); `PKG[@SOURCE]`          |
| `--recipe REF`         | the recipe to run, `COOKBOOK/CHAPTER/RECIPE`                                  |
| `--recipe-args ARGS`   | the recipe's flags; prefer `--recipe-args="--oban-pro --gigalixir"`           |
| `--with TASK`          | the base generator, as in `igniter.new` (`phx.new`, ...); default `new`       |
| `--with-args ARGS`     | arguments for `--with`; prefer `--with-args="--no-ecto --binary-id"`          |
| `--install PKG[,PKG]`  | base packages installed with the app as prod deps (repeatable); `PKG[@SOURCE]` |
| `--composer SOURCE`    | composer's source: `path:...`, `github:...` or a version; default `~> MAJOR.MINOR` of the archive |
| `--extra-dep PKG`      | another dev/test dep that isn't a cookbook (repeatable); `PKG[@SOURCE]`       |
| `--igniter-local PATH` | a local igniter checkout, passed as `igniter.new --local` (made relative to APP's parent) |
| `--reset`              | delete APP first                                                              |
| `--dry-run`            | print the plan and run nothing                                                |

Any other switch is an error. Options other than `--cookbook`,
`--install` and `--extra-dep` may be given once. There is no `--yes`: the
command runs unattended.

A `path:` source, relative or starting with `~`, is made absolute, since
the install runs inside the new app.

## What it runs

The plan (app, cookbooks and their sources, recipe, base generator and
every command) is printed first, every time. `--dry-run` stops there.

0. **Preflight**: the options are valid; APP doesn't exist (unless
   `--reset`); `igniter_new` >= 0.5.32 is installed; the `--with` task's
   archive is installed; `git` is on the PATH; each cookbook that comes
   from Hex is a Hex package (only a warning when Hex can't be reached or
   `HEX_OFFLINE` is set).
1. **Create**: `mix igniter.new APP --no-git --yes`, with `--with`,
   `--with-args` and `--local`.
2. **Install**: in APP, `mix composer_new.install PKG,... --yes` for the
   `--install` packages, then
   `mix composer_new.install composer@SRC,COOKBOOK@SRC,... --only dev,test --yes`.
   The cookbooks' own deps come with them.

   `composer_new.install` ships in this archive. It is
   `mix igniter.install`, except that it reads each `PKG@SOURCE` as
   `--cookbook` does: `igniter.install` rejects a version requirement such as
   `~> 0.3`, while `composer_new.install` writes it to `mix.exs` as given.
3. **Record**: in APP, `git init`, `git add -A`, and a commit whose message
   is the `mix composer.new` command line. `git log --reverse` shows how to
   rebuild the app, and `recipe.run` gets the clean tree it needs.
4. **Run**: in APP, `mix composer.recipe.run COOKBOOK/CHAPTER/RECIPE
   [RECIPE-ARGS]`, which commits the recipe's changes. Skipped without
   `--recipe`.

Each command is its own `mix` (or `git`) process, with its output streamed
to the terminal.

## When something fails

The run stops at the first command that fails, and exits non-zero.

- **Create or install failed**: APP is partial. Fix the cause and rerun the
  same command with `--reset`.
- **The recipe failed** (no such recipe, a mistyped flag, an unmet
  `requires`, a step error): APP is left at its generation commit, and the exact command to
  retry is printed:

  ```bash
  cd my_app && mix composer.recipe.run cb_lab/lv/base --gigalixr
  ```

- **The install failed with the default `--composer`**: that composer
  version may not be on Hex yet; point at a checkout with
  `--composer path:/path/to/composer`.

A cookbook installed from `@github:` or `@git:` must declare hex or git
deps, not path deps: a path is resolved next to the checkout in `deps/`,
where it doesn't exist. `mix composer.cookbook.lint` warns about path deps
in a project with a `package:` section.

## A recipe is code

A cookbook from `@github:` or `@git:` runs someone else's code on your
machine, just as `igniter.new --install` does. To see what a recipe would do
first, give the `--cookbook` without `--recipe`:

```bash
mix composer.new my_app --cookbook cb_lab@github:elixir-composer/cb_lab
cd my_app
mix composer.recipe.show cb_lab/lv/base
mix composer.recipe.run cb_lab/lv/base --dry-run
```

## License

MIT, see [LICENSE.md](LICENSE.md).
