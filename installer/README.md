# composer_new

`mix composer.new` creates an Elixir app and applies a
[composer](https://github.com/elixir-composer/composer) recipe to it, in
one command:

```bash
mix composer.new my_app cb_lab/base/completions --with phx.new --with-args=--no-ecto
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
mix composer.new APP [REF] [RECIPE-FLAGS] [OPTIONS]
```

APP comes first, as with `igniter.new` and `phx.new`. It may have a
directory part (`/tmp/my_app`); its last segment must be a valid app name.

### REF

```
REF    = COOKBOOK/CHAPTER/RECIPE[@SOURCE]
SOURCE = <requirement>                 hex, kept as written: @~> 0.3, @>= 0.3.1
       | <version>                     hex: @0.3.1 is == 0.3.1, @0.3 is ~> 0.3 (no @: the latest)
       | github:OWNER/REPO[@GITREF]
       | git:URL
       | path:PATH
```

REF is split on its first `@`: `COOKBOOK/CHAPTER/RECIPE` goes to
`mix composer.recipe.run`, and `COOKBOOK@SOURCE` to
`mix composer_new.install` (see [What it runs](#what-it-runs)).

```bash
# hex
mix composer.new my_app cb_lab/base/completions
# github, default branch or pinned
mix composer.new my_app cb_lab/base/completions@github:elixir-composer/cb_lab
mix composer.new my_app cb_lab/base/completions@github:elixir-composer/cb_lab@v0.3.0
# a local checkout
mix composer.new my_app cb_home/lv/base@path:~/src/Gen/cb_home --with phx.new
# a base that is a package, not a task
mix composer.new my_blog cb_home/astral/min@path:~/src/Gen/cb_home \
  --install astral@path:~/src/Fork/astral
# recipe flags pass through to composer.recipe.run
mix composer.new my_app cb_mine/phx/saas --oban-pro --gigalixir
```

Rules:

- REF is a qualified recipe address, `COOKBOOK/CHAPTER/RECIPE`: a root
  (`/lv/base`), relative (`./base`) or bare (`base`) address is an error.
- `cb_std/CHAPTER/RECIPE` installs no cookbook (`cb_std` ships with composer), so
  it takes no `@SOURCE`.
- Step addresses (`cb_lab:lv:x`) and `hex:` addresses are rejected.
- Without REF, the app gets composer and nothing else. Run
  `mix composer.init` in it to start the app's own cookbook.

### Options

| Option                 | Meaning                                                                       |
|------------------------|-------------------------------------------------------------------------------|
| `--with TASK`          | the base generator, as in `igniter.new` (`phx.new`, ...); default `new`       |
| `--with-args ARGS`     | arguments for `--with`; prefer `--with-args="--no-ecto --binary-id"`          |
| `--install PKG[,PKG]`  | base packages installed with the app as prod deps (repeatable); `PKG[@SOURCE]` |
| `--composer SOURCE`    | composer's source: `path:...`, `github:...` or a version; default `~> MAJOR.MINOR` of the archive |
| `--extra-dep PKG`      | another dev/test dep, such as a second cookbook (repeatable); `PKG[@SOURCE]`  |
| `--igniter-local PATH` | a local igniter checkout, passed as `igniter.new --local` (made relative to APP's parent) |
| `--reset`              | delete APP first                                                              |
| `--dry-run`            | print the plan and run nothing                                                |
| `--no-recipe`          | create, install and commit, but don't run the recipe                          |

Every other switch is a recipe flag and goes to `mix composer.recipe.run`,
which rejects any flag the recipe doesn't declare before it changes
anything. Everything after `--` is a recipe flag too. There is no `--yes`:
the command runs unattended.

A `path:` source, relative or starting with `~`, is made absolute, since
the install runs inside the new app.

Composer reserves these option names: no recipe may declare a flag called
`with`, `install`, `reset`, `dry_run`, and so on, and
`mix composer.cookbook.lint` says so.

## What it runs

The plan (app, cookbook, source, base generator and every command) is
printed first, every time. `--dry-run` stops there.

0. **Preflight**: the ref and options are valid; APP doesn't exist (unless
   `--reset`); `igniter_new` >= 0.5.32 is installed; the `--with` task's
   archive is installed; `git` is on the PATH.
1. **Create**: `mix igniter.new APP --no-git --yes`, with `--with`,
   `--with-args` and `--local`.
2. **Install**: in APP, `mix composer_new.install PKG,... --yes` for the
   `--install` packages, then
   `mix composer_new.install composer@SRC,COOKBOOK@SRC,... --only dev,test --yes`.
   The cookbook's own deps come with it.

   `composer_new.install` ships in this archive. It is
   `mix igniter.install`, except that it reads each `PKG@SOURCE` as a REF's
   SOURCE: `igniter.install` rejects a version requirement such as
   `~> 0.3`, while `composer_new.install` writes it to `mix.exs` as given.
3. **Record**: in APP, `git init`, `git add -A`, and a commit whose message
   is the `mix composer.new` command line. `git log --reverse` shows how to
   rebuild the app, and `recipe.run` gets the clean tree it needs.
4. **Run**: in APP, `mix composer.recipe.run COOKBOOK/CHAPTER/RECIPE
   [RECIPE-FLAGS]`, which commits the recipe's changes. Skipped without a
   REF, or with `--no-recipe`.

Each command is its own `mix` (or `git`) process, with its output streamed
to the terminal.

## When something fails

The run stops at the first command that fails, and exits non-zero.

- **Create or install failed**: APP is partial. Fix the cause and rerun the
  same command with `--reset`.
- **The recipe failed** (a mistyped flag, an unmet `requires`, a step
  error): APP is left at its generation commit, and the exact command to
  retry is printed:

  ```bash
  cd my_app && mix composer.recipe.run cb_lab/base/completions --gigalixr
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
first:

```bash
mix composer.new my_app cb_lab/base/completions@github:elixir-composer/cb_lab --no-recipe
cd my_app
mix composer.recipe.show cb_lab/base/completions
mix composer.recipe.run cb_lab/base/completions --dry-run
```

## License

MIT, see [LICENSE.md](LICENSE.md).
