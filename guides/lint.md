# Lint and editor diagnostics

`mix composer.cookbook.lint` checks a cookbook and reports every problem as a **diagnostic**: a severity, a stable code, a
file and a range in it. Editors, CI and scripts read the same diagnostics
in the format each understands.

```bash
mix composer.cookbook.lint                     # this project's cookbook
mix composer.cookbook.lint --file PATH         # one recipe group file
mix composer.cookbook.lint --format compact    # text | compact | json | github
```

Each problem is reported where it is written: a bad reference at its
string, a broken `{:use, ...}` at its target, an alias at its name, a
missing key at the recipe's name. A recipe with three typos shows three
diagnostics. A problem in a recipe that others include is reported once,
in the recipe that has it.

## Formats

**text** (the default) prints full messages, each after a clickable
`path:line:col:` location; warnings first, then the errors, which make the
task fail.

**compact** prints one line per diagnostic, for editors:

```
/home/me/src/my_app/lib/composer/my_app/recipes/auth.exs:15:8: error: In recipe my_app:auth/passkeys: no step matches "credoo". Did you mean: cb_std:setup/credo? ... [typo]
/home/me/src/my_app/lib/composer/my_app/recipes/auth.exs:13:15: warning: my_app:auth/magic: alias lab (= cb_lab) is never used. Remove it, or use it. [unused_alias]
```

That is `file:line:col: severity: message [code]`, the shape of GCC and of
Credo's `flycheck` and `oneline` formats (`mix credo --format flycheck`),
so an editor recipe written for `mix credo` adapts by changing the
command. Paths are always absolute; the message is folded onto one line,
dropping its indented examples. A diagnostic with no location is printed
at `:1:1` of the file most related to it, or of the cookbook's
`manifest.exs`, so no line is ever unparseable.

**json** prints an array of diagnostics:

```json
[
  {
    "severity": "error",
    "code": "typo",
    "file": "/home/me/src/my_app/lib/composer/my_app/recipes/auth.exs",
    "line": 15, "column": 8, "end_line": 15, "end_column": 16,
    "message": "In recipe my_app:auth/passkeys: no step matches \"credoo\".\n\n...",
    "suggestions": ["cb_std:setup/credo"],
    "related": []
  }
]
```

`related` lists the other places a problem involves (`file`, the range,
and a `message`): the other install of a `conflicting_install`, each
include of a `cycle`, the first key of a `duplicate_recipe`, and the
problems an `include_problems` summary counts.

**github** prints GitHub Actions workflow commands, which show as inline
annotations on pull requests:

```yaml
- run: mix composer.cookbook.lint --format github
```

### Exit status and stdout

The task exits non-zero when there is an error, in every format; warnings
alone exit zero. In every format but `text`, stdout holds nothing but the
diagnostics: the project is compiled with a quiet Mix shell, and errors
end the task with exit status 1 instead of a raise. Mix compiles
dependencies that need it *before* the task can start; set `MIX_QUIET=1`
to silence that too (or run `mix compile` once beforehand).

## Positions

Lines and columns are 1-based. Columns count characters as Elixir's
tokenizer does (grapheme clusters), not bytes or UTF-16 code units. A
located diagnostic always has an end (`end_line`, `end_column`,
exclusive) as well as a start.

When the exact literal can't be found (a reference built at run time,
such as `"lab:" <> name`), the position falls back to the recipe's
`steps:` key, then its name, then line 1. A slightly vague position beats
none.

## One file: `--file`

Editors lint the file you just saved:

```bash
mix composer.cookbook.lint --format compact --file lib/composer/my_app/recipes/auth.exs
```

`--file` takes one recipe group file and finds its cookbook from the path:
a file under a cookbook's `lib/composer/<name>/recipes/` is that
cookbook's, whether it is the project's own or a dependency's. Every
cookbook is still loaded, since includes cross files, but only that file's
diagnostics are printed, and lint exits zero when it has none, whatever
other files hold.

A `{:use, ...}` of a recipe that has problems of its own gets one summary
diagnostic, `include_problems` ("my_app:ash/base has 2 problems."), with
those problems as related locations. Otherwise a broken include would look
fine from the including file.

## The host project is your editor's working directory

Lint runs inside a Mix project, which provides the installed cookbooks
your recipes refer to. A recipe group file lives in a cookbook, so the
host is that cookbook's project. From an editor, it is the editor's
working directory: start the editor there,

```bash
cd ~/src/my_app && nvim lib/composer/my_app/recipes/auth.exs
```

and every integration below runs `mix` there. The file is passed by its
absolute path, its cookbook is found from it, and compact output uses
absolute paths, so diagnostics land on the right buffer.

Don't set a `cwd` in the editor configs. Things that move the working
directory (`:cd`, `autochdir`, project-root plugins) break this: lint then
fails with "must be run inside a Mix project", or checks against another
project's cookbooks.

## Editors

For warm diagnostics with no `mix` startup on save, plus hover,
goto-definition, completion and quick fixes, use the language server
instead: see the [Composer LSP guide](composer_lsp.md). The setups below
run lint once per save.

### Vim and Neovim: `:make` and the quickfix list

No plugin needed:

```vim
" e.g. in an autocmd for */lib/composer/*/recipes/*.exs
setlocal makeprg=mix\ composer.cookbook.lint\ --format\ compact\ --file\ %:p
setlocal errorformat=%f:%l:%c:\ %trror:\ %m,%f:%l:%c:\ %tarning:\ %m
```

Then `:make` and `:copen`.

### Neovim: nvim-lint, on save

```lua
local lint = require("lint")

lint.linters.composer = {
  cmd = "mix",
  args = { "composer.cookbook.lint", "--format", "compact", "--file" },
  stdin = false,
  append_fname = true, -- appends the buffer's full path
  stream = "stdout",
  ignore_exitcode = true, -- errors exit 1
  parser = require("lint.parser").from_errorformat(
    "%f:%l:%c: %trror: %m,%f:%l:%c: %tarning: %m",
    { source = "composer" }
  ),
}

vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = { "*/lib/composer/*/recipes/*.exs" },
  callback = function() lint.try_lint("composer") end,
})
```

nvim-lint runs the linter in Neovim's working directory, the host project.
Avoid its `env` field for `MIX_QUIET`: it replaces the whole environment.
Lines that don't match the errorformat (such as dependency compile output
on a first run) are ignored.

### VS Code: a task with a problem matcher

Open the host project as the workspace, and add to `.vscode/tasks.json`:

```json
{
  "version": "2.0.0",
  "tasks": [{
    "label": "composer lint",
    "type": "shell",
    "command": "mix composer.cookbook.lint --format compact --file ${file}",
    "problemMatcher": {
      "owner": "composer",
      "fileLocation": "absolute",
      "pattern": {
        "regexp": "^(.*):(\\d+):(\\d+): (error|warning): (.*)$",
        "file": 1, "line": 2, "column": 3, "severity": 4, "message": 5
      }
    }
  }]
}
```

Diagnostics land in the Problems panel and as squiggles. Run the task on
save with an extension such as "Trigger Task on Save".

### Helix, Zed and others: efm-langserver

[efm-langserver](https://github.com/mattn/efm-langserver) turns a command
and an errorformat into a language server:

```yaml
languages:
  elixir:
    - lint-command: "mix composer.cookbook.lint --format compact --file ${INPUT}"
      lint-stdin: false
      lint-ignore-exit-code: true
      lint-formats:
        - "%f:%l:%c: %trror: %m"
        - "%f:%l:%c: %tarning: %m"
```

## Diagnostic codes

The code is the reason's tag. Codes are stable: editor configs and
scripts may match on them.

| Code | Problem |
|------|---------|
| `typo` | an unqualified name close to a step id (`suggestions` holds the candidates) |
| `missing_step` | no step matches a reference |
| `missing_recipe` | no recipe matches a `{:use, ...}` |
| `ambiguous` | an unqualified name matches in several cookbooks |
| `unknown_cookbook` | a reference names a cookbook that is not installed |
| `unknown_alias_target` | a cookbook alias names a cookbook that is not installed |
| `via_alias` | a problem with a reference written through an alias |
| `invalid_ref` | a malformed reference string |
| `dep_opts_on_step` | package options on a reference that names a step |
| `conflicting_install` | one package installed with different options |
| `cycle` | recipes that include each other |
| `include_problems` | (`--file`) an included recipe has problems |
| `invalid_entry`, `legacy_form` | a malformed or old-style step entry |
| `unknown_entry_option`, `bad_entry_option`, `hex_only_option` | a bad entry option |
| `multiple_sources`, `source_conflict`, `git_option_without_git`, `multiple_git_refs`, `repo_source` | inconsistent `hex:` sources |
| `recipe_missing_key`, `unknown_recipe_key`, `bad_recipe_value`, `recipe_shape` | a malformed recipe |
| `multiline_shortdoc` | a `shortdoc` on more than one line |
| `undeclared_flag` | an `if:` flag the recipe does not declare |
| `reserved_flag` | a declared flag with a reserved name (`Composer.Recipe.reserved_flags/0`) |
| `invalid_alias`, `reserved_alias`, `duplicate_alias`, `alias_atom_target`, `invalid_alias_target`, `alias_shadows_cookbook` | a bad cookbook alias |
| `unused_alias` (warning) | an alias none of the recipe's references use |
| `inconsistent_alias` (warning) | one alias naming different cookbooks in one group |
| `duplicate_recipe`, `invalid_recipe_name`, `group_recipe_clash` | recipe names |
| `group_parse`, `recipe_eval`, `group_shape`, `group_read` | a group file that does not parse, raises, or is not a keyword list |
| `invalid_group_name`, `recipes_subdir`, `empty_group` (warning) | group files |
| `legacy_recipes_dir` | a leftover `profiles/` directory in the cookbook |
| `step_missing_meta`, `missing_step_test`, `requires_unresolved` | a step's metadata, test and `requires` |
| `manifest_missing`, `manifest_stale` | the cookbook's manifest |
| `step_recipe_clash` (warning) | a step and a recipe share an id |
| `legacy_templates_dir`, `orphaned_templates`, `unprefixed_templates`, `not_a_step`, `missing_template` | templates and files under `steps/` |
| `unused_template` (warning) | a template no `template/1` call refers to |
| `path_dep_in_package` (warning) | a path dependency in a project with a `package:` section |

Step problems are placed in the step's source file: at its
`use Composer.Step`, or at the `template/1` path or `requires` reference
in question.

## From Elixir

`Composer.Lint` is a set of plain functions over discovered cookbooks;
it prints nothing and returns `%{diagnostics: [Composer.Lint.Diagnostic.t()]}`
(`run/3`), or per-file results for a set of group files
(`files/3`). `Lint.owner/2` finds the cookbook a group file belongs to,
`Lint.dependents/2` lists the recipes that include a recipe, directly or
not, and `Composer.Recipe.Locator` indexes a group file's
source (without evaluating it) for forward and cursor lookups.
