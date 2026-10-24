# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Composer is an Elixir library (built on Igniter) that turns post-`phx.new`
setup into **recipes**: ordered, flag-aware lists of **steps** that run as
one reviewable Igniter diff. It is used as a `:dev` dependency inside a
Phoenix app; it targets only the latest stable Phoenix (1.8) and its
`phx.new` output.

## Commands

These mirror CI (`.github/workflows/ci.yml`):

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix composer.cookbook.lint             # lints the built-in `cb_std` cookbook
mix test                               # integration tests excluded by default
mix test --include integration         # also builds a real host app (slow)
mix test test/composer/resolver_test.exs:42   # single test
```

Many tests use `Igniter.Test.phx_test_project/1`, which needs the `phx_new`
archive installed (`mix archive.install hex phx_new --force`).

`test/test_helper.exs` disables network version lookups (`fetch_versions:
false`) and completion-index writes, so tests are offline.

CI also runs a "golden" job: a fresh `phx.new` app runs `mix composer.init
--yes` then `mix composer.recipe.run default ...`, and fails if any step
logs that it no-oped ("Nothing was modified", "skipped adding/removing...",
"was skipped"). Steps that pattern-match `phx.new` output must warn loudly
when they find nothing, never silently no-op.

## Architecture

The pipeline for a run: **Discovery → Resolver → Preflight → Runner → Git**.

- `Composer.Discovery` finds cookbooks by convention, not scanning: for each
  dep app (and the current project) it checks whether `Composer.<App>` is
  loaded and is a cookbook. Order: `cb_std`, current project, deps.
  Deps must be compiled first, which is why every task calls `compile`
  (`Composer.CLI`). `hex` is a virtual cookbook known only to the Resolver.
- `Composer.Resolver` resolves references (`"cookbook:path"`, unqualified
  names, `hex:pkg`, `{:use, recipe}` includes) and flattens the recipe tree
  into one acyclic, deduped, flag-filtered list of entries. Unqualified
  lookup: referring cookbook first, then all cookbooks (ambiguity is an
  error), then Hex fallback — unless the name looks like a typo of a step id.
- `Composer.Preflight` checks each step's `requires` before anything runs.
- `Composer.Runner` executes `{:module, ...}`, `{:install, pkg}`,
  `{:task, ...}`, `{:queue, ...}` entries in order into one igniter. Hex
  packages are added and fetched *before* any step (installers must be on
  disk); queued tasks run last with `--yes` only.
- `Composer.Git` makes `recipe.run` a single commit (refuses dirty tree).

### Cookbooks, steps, recipes

A cookbook is a package's tree at `lib/composer/<name>/` declared by
`lib/composer/<name>.ex` (`use Composer.Cookbook`); the name must equal the
OTP app, except the built-in `cb_std` (`lib/composer/cb_std/`). Layout:
`steps/` (each step's templates in the directory beside it, `steps/_<id>/`),
`recipes/<chapter>.exs`, `manifest.exs`. There is no cookbook-level
`templates/`.

- **Steps** (`use Composer.Step`) are `Igniter.Mix.Task` modules, *not* Mix
  tasks. The module name must match the file path
  (`lib/composer/cb_std/steps/cluster/gigalixir/libcluster.ex` →
  `Composer.CbStd.Steps.Cluster.Gigalixir.Libcluster`) or compilation fails.
  Metadata vocabulary (action, phase, stability, frameworks, capability...) lives in
  `Composer.Facets`.
- **Chapters** are `.exs` keyword lists evaluated as literal data and
  validated by `Composer.Recipe.Chapter`; recipes are addressed
  `cookbook:chapter/name`. Personal recipes live in an ordinary cookbook
  added as a path dependency; `local` is only a reserved name.
- **Templates**: `template("x.eex")` inside a step is relative to
  `steps/_<id>/` (`Composer.Step.template_dir/1`; step path segments never
  start with `_`), checked at compile time and registered as an external
  resource; refs are `{cookbook, step_id, path}`, and code outside a step
  uses `Composer.Templates.ref(StepModule, path)`. Every `.ex` under
  `steps/` must be a step (Elixir templates are `.ex.eex`); lint reports
  orphaned, unprefixed and unused template files.
- Step helpers: `Composer.Templates` (EEx/template copying),
  `Composer.Helpers` (app/repo module names, checked file edits, migration
  timestamps), `Composer.Versions` (latest Hex/npm/GitHub versions, falling
  back to permissive ranges offline).

### Adding or changing a built-in step

`mix composer.cookbook.lint` (`Composer.Lint`) enforces, and CI fails on:
- every step has `summary`, `action`, `stability`
- a test exists at `test/composer/cb_std/steps/<id>_test.exs`
- `lib/composer/cb_std/manifest.exs` matches — regenerate with
  `mix composer.cookbook.manifest` after changing step metadata (never edit
  it by hand)

Also update the built-in steps table in `README.md`. Policy: Composer ships
**no step for packages that have their own Igniter installer** (oban,
tidewave, ash...) — those are run as `hex:<pkg>`; built-in steps exist only
where upstream ships nothing.

Step tests compose the step against `Igniter.Test.test_project()` (or
`phx_test_project()`) and assert on `diff/2`. Fake cookbooks used by tests
live in `test/support/cookbooks/`; `test/fixtures/fake_dep` is a whole Mix
project for the integration test. `.exs` files under
`lib/composer/*/steps/` (verbatim templates) and `test/support/fixtures/`
are excluded from formatting on purpose.

### Other pieces

- `lib/mix/tasks/composer.*.ex` — thin Mix task wrappers; shared plumbing in
  `Composer.CLI`. Listing tasks support `--json`.
- `Composer.Index` writes `_build/composer/index` (plain text) so shell
  completion (`priv/completion/`) never starts the BEAM; every task refreshes
  it.

## The `composer_new` archive (`installer/`)

`installer/` is a separate Mix project, the `composer_new` archive that
provides `mix composer.new` (create an app with `igniter.new`, install
composer and a cookbook, commit, run a recipe). It has **no runtime deps**
(an archive can't carry them), so `ComposerNew.Ref` is a copy of
`Composer.Ref`'s name and `@source` rules; `installer/test/fixtures/refs.exs`
is read by both projects' tests to keep them in step. Packages are
installed with the archive's own `mix composer_new.install` (which hands
Igniter dep tuples), not `mix igniter.install`, because igniter.install
rejects version requirements such as `~> 0.3`. Composer itself
must never define `Mix.Tasks.Composer.New`. Run its checks from
`installer/` (`mix test`, `mix test --only integration`). Its `@version`
is bumped by git_ops together with composer's (`managed_files` in
`config/config.exs`); a test fails if they differ.

## Specs and docs

Design docs, feature specs and implementation plans live in
`_spec/{designs,features,plans}/` (date-prefixed, `YYMMDD_name.md`). User
guides are in `guides/` and are published via ExDoc.

`CHANGELOG.md` is generated by `git_ops` from Conventional Commit messages
at release time (`bin/release`). Never edit it by hand, and don't mention
leaving it untouched.
