# Bundling a cookbook with your framework

A framework can ship a composer cookbook inside its own package. An app
that installs the framework gets the framework's steps and recipes with it,
at the same version, with no separate `cb_*` package to find and keep in
step.

Composer stays optional. An app that doesn't use composer never fetches it,
and in production the cookbook compiles to nothing.

This guide uses a framework called `my_fw`.

## The shape of it

- **The cookbook is named after your OTP app.** `my_fw`'s cookbook is
  `my_fw`, declared by `Composer.MyFw` in `lib/composer/my_fw.ex`, with its
  tree in `lib/composer/my_fw/`. Its recipes are `my_fw/CHAPTER/RECIPE`. See
  `Composer.Cookbook` for the layout.
- **Composer is an optional dependency of your framework**, so it is only
  there when the app has it too.
- **Every file of the cookbook is guarded** with
  `if Code.ensure_loaded?(Composer) do ... end`, so where composer is
  absent it compiles to nothing.

## 1. Depend on composer, optionally

```elixir
# my_fw/mix.exs
defp deps do
  [
    {:composer, "~> 0.4", optional: true}
  ]
end
```

Write `optional: true` and **no `only:`**.

- `optional: true` means an app that installs `my_fw` doesn't get composer
  with it. An app that also depends on composer gets the one it asked for.
- `only: :dev` looks harmless but breaks the cookbook. Mix builds every
  dependency in its `:prod` environment, so in an app, your `only: :dev`
  dependency doesn't exist. Mix then doesn't know that `my_fw` must compile
  after composer, the guard can find `Composer` not yet loaded, and the
  cookbook compiles to nothing, in dev as well.

In your framework's own repository, the optional dependency is fetched like
any other, so you can work on and test the cookbook there.

## 2. Generate the cookbook

```bash
mix composer.gen.cookbook --bundled
```

`--bundled` writes the cookbook module inside the guard:

```elixir
if Code.ensure_loaded?(Composer) do
  defmodule Composer.MyFw do
    use Composer.Cookbook, summary: "Composer steps and recipes for my_fw"
  end
end
```

From then on, `mix composer.gen.step` sees the guard in the cookbook module
and wraps each new step, and its test, the same way. A step you write by
hand needs the guard too. Templates and chapter files (`.eex`, `.exs`
under `lib/composer/my_fw/`) aren't compiled, so they need nothing.

Before you publish, run `mix composer.cookbook.manifest` and
`mix composer.cookbook.lint` in the framework's repository, as for any
cookbook (see the [Cookbooks guide](cookbooks.md)).

## What an app sees

| The app...                      | in dev and test                    | in prod                       |
|---------------------------------|------------------------------------|-------------------------------|
| depends on composer (dev/test)  | the `my_fw` cookbook is found      | composer is absent; nothing   |
| doesn't depend on composer      | nothing                            | nothing                       |

The framework itself is a normal, prod dependency of the app. Only composer
is dev/test-only. Composer never runs in a release anyway: its tasks are Mix
tasks, and a release has no Mix.

## Creating an app with `mix composer.new`

Give the framework with `--install`, as a prod dependency, and run one of
its recipes with `--recipe`:

```bash
mix composer.new my_app --install my_fw --recipe my_fw/setup/default
```

`--recipe` looks for its cookbook in this order:

1. `cb_std`, which ships with composer
2. a `--cookbook` of that name
3. an `--install` package of that name: a framework that bundles its
   cookbook, as here
4. otherwise, the latest Hex release of that name

So `my_fw` is installed once, as a prod dependency, and not again as a
cookbook. Giving it with both `--install` and `--cookbook` is an error.

`mix composer.new` installs composer before the `--install` packages, so
`my_fw` is compiled with composer present and the guard keeps its
cookbook.

## Adding composer to an app that already has the framework

Mix doesn't recompile a dependency when one of its optional dependencies
appears later. If the app had `my_fw` before it had composer, `my_fw` was
compiled without its cookbook, and stays that way after `mix deps.get`:

```
"my_fw/setup/default" names the cookbook "my_fw", which is not installed.
...
my_fw is a dependency, but defines no cookbook. If it bundles one, it was
probably compiled before composer was added. Recompile it: mix deps.compile my_fw --force
```

Do what it says once:

```bash
mix deps.compile my_fw --force
```

## Versions

Your framework's composer requirement and the app's must agree. Use a wide
requirement, such as `~> 0.4`, and widen it as composer releases. An app
that points composer at a git checkout or a path gets a conflict with
your Hex requirement; it marks its own composer dependency with
`override: true`, which `mix composer.new` does for `--composer path:...`.

A published framework must depend on composer from Hex or git, never by
path: a path is resolved inside the app's `deps/`, where it points at
nothing. `mix composer.cookbook.lint` warns about path dependencies in a
project with a `package:` section.
