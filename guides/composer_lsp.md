# Composer LSP

WARNING: this is experimental.  Proceed at your own risk! 

`composer-ls` is a language server for recipe group files. It runs
*beside* your Elixir language server (ElixirLS, Next LS, Expert), handles
only recipe references, and replaces nothing. It keeps your cookbooks
loaded in one BEAM, so there is no `mix` startup on each save.

It gives the editor:

- **Diagnostics** on open and on save: the same diagnostics as
  `mix composer.cookbook.lint --file` (see the [lint guide](lint.md)), in
  the saved file *and* in the files that include its recipes. When you fix
  a typo in `cb_mine:ash/base`, the "has 1 problem" summary disappears from
  `app.exs` without opening it.
- **Hover** on a reference: a step's metadata and docs, a recipe's
  shortdoc, flags and entries, what a `hex:` package (or an unqualified
  name that falls through to Hex) does, or an alias's target cookbook. A
  reference that doesn't resolve shows why.
- **Goto-definition**: a step's source (also under `deps/`), a recipe's
  key in its group file, or an alias's entry in `aliases:` (or the
  top-level binding it names). `hex:` references link to HexDocs.
- **Completion** of step ids, recipe ids and the recipe's alias prefixes
  in `steps:`, and of recipe ids in `{:use, "`, even while the buffer
  doesn't parse.
- **Quick fixes** that replace a typo with lint's suggestion.

## Install

`composer-ls` ships with composer: a host with composer in its deps
needs nothing more.

## Start: the host is the recipe's project

```bash
mix composer.lsp
```

starts the server on stdio. Your editor runs this for you.

Recipes refer to the cookbooks installed in a project, so the server
needs one: the **host project** is the directory the server starts in.
A recipe group file lives in a cookbook, `lib/composer/<name>/recipes/`,
inside that cookbook's Mix project, so the host is the nearest `mix.exs`
above the file. Open the recipe in its project:

```bash
cd ~/src/cb_mine && nvim lib/composer/cb_mine/recipes/auth.exs
```

There is no settings file or environment variable for this. A reference
valid in one host may be invalid in another, and that is expected: the
server names the host in a message at startup
(`composer-ls: host project cb_mine at /home/you/src/cb_mine`) and at the
foot of every hover.

Started outside a Mix project, the server exits at once with "must be run
inside a Mix project".

### Dependencies are not edited in place

A cookbook installed as a dependency also has its recipes under
`deps/<name>/lib/composer/<name>/recipes/`, but the server doesn't attach
there. `mix deps.get` overwrites `deps/`, and a dependency has no `_build`
of its own to host the server. To edit a cookbook, open its own checkout
(for a path dependency, the directory the path points at).

## Neovim

This needs Neovim 0.12, where a `cmd` function receives the resolved
config:

```lua
vim.lsp.config("composer_ls", {
  -- Run mix in the root (the recipe's project), not Neovim's cwd.
  cmd = function(dispatchers, config)
    return vim.lsp.rpc.start({ "mix", "composer.lsp" }, dispatchers, {
      cwd = config.root_dir,
      -- Keep Mix's own output (compiling dependencies) off stdout.
      env = { MIX_QUIET = "1" },
    })
  end,
  filetypes = { "elixir" },
  -- Attach to a cookbook's recipe files only, rooted at the nearest
  -- mix.exs. Files under deps/ get no server.
  root_dir = function(bufnr, on_dir)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name:match("/lib/composer/[^/]+/recipes/[^/]+%.exs$")
      and not name:match("/deps/")
    then
      local root = vim.fs.root(bufnr, "mix.exs")
      if root then on_dir(root) end
    end
  end,
})

vim.lsp.enable("composer_ls")
```

`root_dir` calls `on_dir` only for recipe files, so other `.exs` files
don't start the server. The root comes from the file, not from Neovim's
working directory, so `:cd` and file explorers don't move it. Neovim
reuses a client whose name and root match, so the recipes of one
cookbook share one `composer_ls` client, and each cookbook project gets
its own. `:checkhealth vim.lsp` lists them.

Both parts matter. `root_dir` picks the project, but without the `cmd`
function the server would run `mix` in Neovim's current directory, which
it inherits. The `cmd` function starts it in the root.

Neovim's LSP mappings apply: `K` hovers and `gra` lists the quick fixes.
Map `vim.lsp.buf.definition()` (commonly to `gd`) for goto-definition.
Completion arrives through your completion plugin or
`vim.lsp.completion.enable()`. The HexDocs links of `hex:` references are
LSP document links, for clients and plugins that show them.

### Turn off nvim-lint for these buffers

If you followed the [lint guide](lint.md) and run `composer.cookbook.lint`
through nvim-lint on save, remove that autocmd: the server reports the
same diagnostics, and both together show each problem twice.

### Reload after editing step code

Recipe edits need nothing: group files are read again on every lint.
Steps are compiled code, though, so after editing a step in a path-dep
cookbook, run the `composer.reload` command. It recompiles the project
and rediscovers the cookbooks, then reports "composer-ls: reloaded N
cookbooks" (or the compile error):

```lua
vim.api.nvim_create_user_command("ComposerReload", function()
  for _, client in ipairs(vim.lsp.get_clients({ name = "composer_ls" })) do
    client:exec_cmd({ title = "Reload cookbooks", command = "composer.reload" })
  end
end, {})
```

The server compiles only at startup and on reload, never while idle.
Restarting the server (`:lsp restart` in Neovim 0.12) does the same and
more; restart after changing composer itself.

## Troubleshooting

**Nothing attaches.** Check `:checkhealth vim.lsp`. The buffer's path
must match the `root_dir` pattern, outside `deps/`, and `mix composer.lsp`
must start in the recipe's project: run it in a terminal there. It should
print nothing and wait for input.

**The wrong project, or unknown cookbooks.** The startup message and the
hover footer name the host: the nearest `mix.exs` above the recipe file.
A cookbook referenced by the recipe must be a dependency of that
project.

**The server died at startup, or garbage in the log.** Only protocol
messages may go to stdout. The server sends its own logging, and any
output from steps, cookbooks or recipe group files, to stderr, which
Neovim writes to its LSP log (`:lua vim.cmd.tabnew(vim.lsp.log.get_filename())`).
Mix itself prints dependency compilation on stdout before the server
starts; `MIX_QUIET=1` (in the `cmd` function above) silences it.

**Stale step metadata or docs.** Run `composer.reload`, or restart the
server. A reload while `mix composer.recipe.run` compiles in a terminal
may contend for `_build`; wait for the run to finish.

**Diagnostics differ from the buffer.** Diagnostics come from the file on
disk, on open and on save, as lint's do. Hover and completion follow the
unsaved buffer.
