# Templates

A step can ship files to write into apps. They live beside the step, in
the directory named after its file with a leading underscore:

```
lib/composer/cc_lab/steps/phoenix/
  sidebar_layout.ex                                   # the step
  _sidebar_layout/                                    # its templates
    app_fn.ex.eex
    files/lib/__web_dir__/components/layouts/root.html.heex
    files/lib/__web_dir__/components/sidebar.ex.eex
```

There is one place to look for a step's templates, and removing or
renaming a step takes its templates with it. The underscore tells a
template directory from a directory of child steps at a glance. Templates are not shared
between steps.

Steps write them with `Composer.Templates`. Inside a step, `template/1`
takes a path relative to the step's template directory:

```elixir
defmodule Composer.CcLab.Steps.Phoenix.SidebarLayout do
  use Composer.Step,
    summary: "Replaces the app layout with a sidebar layout",
    action: :patch,
    frameworks: [:phoenix],
    stability: :beta

  alias Composer.Templates

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    layouts = Module.concat([Templates.assigns(igniter).web_module, "Layouts"])

    igniter
    |> Templates.require_present({:dep, :heroicons}, "the sidebar layout uses heroicons")
    |> Templates.copy_dir(template("files"), ".")
    |> Templates.replace_function(layouts, :app, 1, template("app_fn.ex.eex"))
  end
end
```

## Checked at compile time

`template/1` checks that the file or directory exists when the step
compiles. A typo fails `mix compile`, naming the step, the path and where
it looked:

```
** (CompileError) lib/composer/cc_lab/steps/phoenix/sidebar_layout.ex:15:
Composer.CcLab.Steps.Phoenix.SidebarLayout: template "app_fn.eex" does not exist.
```

The file is also registered as an external resource, so editing a template
recompiles its step. A path may not leave the step's template directory
(`template("../other/x")` is a compile error).

A path computed at run time — `template("components/#{name}.astral")` — is
only checked when the step runs, against the step's template directory. Prefer a
literal path where you can.

## Child steps and templates

A step's child steps live in the directory named after its file, and its
templates in the same name with a leading underscore, so a step can have
both:

```
steps/cluster/gigalixir.ex                   # Composer.CbStd.Steps.Cluster.Gigalixir
steps/cluster/_gigalixir/some.conf.eex       # template("some.conf.eex") in Gigalixir
steps/cluster/gigalixir/libcluster.ex        # Composer.CbStd.Steps.Cluster.Gigalixir.Libcluster
steps/cluster/gigalixir/_libcluster/x.eex    # template("x.eex") in Libcluster
```

Step path segments never start with `_`, so the first directory on a
file's path that does names the step that owns it. Only that directory
needs the underscore: subdirectories inside it are named freely.

## From outside a step

Code that is not a step — a helper module shared by a cookbook's steps, or
a test — refers to a step's templates with `Composer.Templates.ref/2`,
naming the step module:

```elixir
Composer.Templates.ref(Composer.CcLab.Steps.Astral.DaisyComponents, "components/button.astral")
#=> {"cc_lab", "astral/daisy_components", "components/button.astral"}

Composer.Templates.path(ref)   # the absolute path, raising when it is missing
```

Renaming the step without updating the caller is an "undefined module"
compile warning, rather than a wrong path. The file itself is only checked
when the reference is used.

## Rendering

Only files ending in `.eex` are rendered, with EEx, and written without the
`.eex` extension. Every other file is copied verbatim, so a template that
contains its own `<%= %>` tags — a HEEx or Astral template — is safe.

`.eex` templates see assigns as `@name`. `Composer.Templates.assigns/1`
builds the standard ones for the target app:

| Assign        | Example      |
|---------------|--------------|
| `@app_name`   | `my_app`     |
| `@app_module` | `MyApp`      |
| `@web_module` | `MyAppWeb`   |
| `@web_dir`    | `my_app_web` |

and every helper merges the assigns you pass over them.

### Elixir source is `.ex.eex`

Store Elixir source as `.ex.eex`, even when it has no EEx tags. Every `.ex`
file under `steps/`, template directories included, is compiled as part of
your package, so `use Composer.Cookbook` rejects one that is not a step, with
a compile error naming the file.

## Path variables

A path segment such as `__web_dir__` is replaced with the matching assign:
`lib/__web_dir__/components/sidebar.ex.eex` is written to
`lib/my_app_web/components/sidebar.ex`. A variable with no assign raises,
naming the variable and the template, rather than writing a literal
`__web_dir__` directory.

## Helpers

| Helper                                                              | Does                                                                            |
|---------------------------------------------------------------------|---------------------------------------------------------------------------------|
| `copy_file(igniter, template, target, opts)`                        | writes one file                                                                 |
| `copy_dir(igniter, template, target_dir, opts)`                     | writes every file under a directory, keeping the layout (`.gitkeep` is skipped) |
| `replace_function(igniter, module, name, arity, template, assigns)` | replaces a function in an existing module with the rendered `def`               |
| `insert(igniter, path, content, at: ...)`                           | adds content `{:after, anchor}`, `{:before, anchor}` or at `:append`            |
| `require_present(igniter, {:dep, name} \| {:file, path}, reason)`   | warns when a prerequisite is missing                                            |

When a target file already exists, `copy_file` and `copy_dir` overwrite it
by default; the change is still shown in the Igniter diff before anything is
written. Pass `on_exists: :skip` to keep existing files.

`replace_function` and `insert` never crash on an app that has drifted from
what the step expects: a missing function, module or anchor is a loud
warning, so changes in Phoenix's generators surface instead of silently
no-oping.

## Personal templates

Templates always live beside a step in a cookbook. Put personal steps, and
the templates beside them, in your own cookbook package added as a path
dependency; see [Personal cookbook](cookbooks.md#personal-cookbook).

## Lint

`mix composer.cookbook.lint` reports, as errors, a leftover cookbook-level
`templates/` directory, files under `steps/` that no step owns (a
`_name/` directory with no matching `name.ex`, or a file outside any
template directory), templates left in an unprefixed `steps/<id>/`
directory (it names the rename), and a `.ex` file there that is not a
step. A template file that no `template/1` call refers to is a warning;
steps whose `template/1` path is computed at run time are not checked.
