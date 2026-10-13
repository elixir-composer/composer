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
  a typo in `local:ash/base`, the "has 1 problem" summary disappears from
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

## Start: the working directory is the host project

```bash
mix composer.lsp
```

starts the server on stdio. Your editor runs this for you.

Recipes refer to the cookbooks installed in a project, so the server
needs one: the **host project** is the directory the editor starts the
server in. Start your editor from the host project:

```bash
cd ~/src/my_app && nvim ~/.config/composer/recipes/auth.exs
```

There is no settings file or environment variable for this. A reference
valid in one host may be invalid in another, and that is expected: the
server names the host in a message at startup
(`composer-ls: host project my_app at /home/you/src/my_app`) and at the
foot of every hover.

Started outside a Mix project, the server exits at once with "must be run
inside a Mix project".

## Neovim

This uses `vim.lsp.config` and `vim.lsp.enable`, from Neovim 0.11:

```lua
vim.lsp.config("composer_ls", {
  cmd = { "mix", "composer.lsp" },
  -- Keep Mix's own output (compiling dependencies) off stdout.
  cmd_env = { MIX_QUIET = "1" },
  filetypes = { "elixir" },
  -- Attach to recipe files only: local recipes and a cookbook's recipes.
  -- The root is Neovim's working directory, the host project, so every
  -- recipe buffer shares one client per host.
  root_dir = function(bufnr, on_dir)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name:match("/composer/recipes/[^/]+%.exs$")
      or name:match("/lib/composer/[^/]+/recipes/[^/]+%.exs$")
    then
      on_dir(vim.fn.getcwd())
    end
  end,
})

vim.lsp.enable("composer_ls")
```

`root_dir` calls `on_dir` only for the two kinds of recipe file, so other
`.exs` files don't start the server. Neovim reuses a client whose name
and root match, so a local recipe and a cookbook's recipe opened in one
session share one `composer_ls` client. `:checkhealth vim.lsp` lists it.

Neovim's LSP mappings apply: `K` hovers and `gra` lists the quick fixes.
Map `vim.lsp.buf.definition()` (commonly to `gd`) for goto-definition.
Completion arrives through your completion plugin or
`vim.lsp.completion.enable()`. The HexDocs links of `hex:` references are
LSP document links, for clients and plugins that show them.

### Keep the host when the working directory changes

The configuration above roots the server at Neovim's working directory
when a recipe buffer opens. Change directory first, and the next recipe
starts a second server there. A file explorer does this when it offers
to make the recipes directory the working directory (nvim-tree asks "do
you want to change your CWD?"). If that directory is not a Mix project,
the server exits with "must be run inside a Mix project".

To browse a recipes or steps directory and keep one server, pin the host
on the first recipe and run `mix` there. This variant needs Neovim 0.12,
where a `cmd` function receives the resolved config:

```lua
-- Host Mix project that runs `mix composer.lsp`; set on first attach.
local host_root = nil

local function find_host_root()
  local root = vim.fs.root(vim.fn.getcwd(), "mix.exs")
  if root then host_root = host_root or root end
  return host_root
end

vim.lsp.config("composer_ls", {
  -- Run mix from the host root, not Neovim's (possibly changed) cwd.
  cmd = function(dispatchers, config)
    return vim.lsp.rpc.start({ "mix", "composer.lsp" }, dispatchers, {
      cwd = config.root_dir,
      -- Keep Mix's own output (compiling dependencies) off stdout.
      env = { MIX_QUIET = "1" },
    })
  end,
  filetypes = { "elixir" },
  root_dir = function(bufnr, on_dir)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name:match("/composer/recipes/[^/]+%.exs$")
      or name:match("/lib/composer/[^/]+/recipes/[^/]+%.exs$")
    then
      local root = find_host_root()
      if root then
        on_dir(root)
      else
        vim.notify("composer_ls: no host Mix project; start nvim in one", vim.log.levels.WARN)
      end
    end
  end,
})
```

The host is the nearest `mix.exs` at or above the working directory when
the first recipe opens. After that every recipe buffer gets the same
root, so Neovim reuses the one client. Neither `:cd` nor a steps
directory in another Mix project moves it. To change host, restart
Neovim from the other project.

Both parts matter. A pinned `root_dir` alone keeps the client, but a
restarted server would still run `mix` in Neovim's current directory:
without `cmd_cwd`, the process inherits it. The `cmd` function starts it
in the root.

If `~/.config/composer` is a symlink, Neovim names the buffer by its
resolved path, which may not match `/composer/recipes/`. Also accept
paths under the resolved directory:

```lua
local local_dir = vim.fn.resolve(vim.fn.expand("~/.config/composer/recipes")) .. "/"
-- in root_dir: ... or vim.startswith(name, local_dir)
```

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
must match one of the two `root_dir` patterns, and `mix composer.lsp`
must start in the host project: run it in a terminal there. It should
print nothing and wait for input.

**The wrong project, or unknown cookbooks.** The startup message and the
hover footer name the host. Things that move Neovim's working directory
(`:cd`, `autochdir`, project-root plugins) before the first recipe buffer
opens give the server another project, or none. Moving it afterwards
starts a second server in the new directory; see [Keep the host when the
working directory changes](#keep-the-host-when-the-working-directory-changes).

**The server died at startup, or garbage in the log.** Only protocol
messages may go to stdout. The server sends its own logging, and any
output from steps, cookbooks or recipe group files, to stderr, which
Neovim writes to its LSP log (`:lua vim.cmd.tabnew(vim.lsp.log.get_filename())`).
Mix itself prints dependency compilation on stdout before the server
starts; `MIX_QUIET=1` (in `cmd_env` above) silences it.

**Stale step metadata or docs.** Run `composer.reload`, or restart the
server. A reload while `mix composer.recipe.run` compiles in a terminal
may contend for `_build`; wait for the run to finish.

**Diagnostics differ from the buffer.** Diagnostics come from the file on
disk, on open and on save, as lint's do. Hover and completion follow the
unsaved buffer.
