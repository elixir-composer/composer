# Shell completion

How Tab completion works for `mix` in a composer project, which program
answers each kind of completion, and which file it reads. Nearly every
completion bug comes down to one question: **who writes that file, and
when does it go stale?**

## Two programs, one `mix` completion

A shell holds one completion function per command. Two programs want `mix`:

| Program                   | Completes                                    | Reads                   | Shells          |
|---------------------------|----------------------------------------------|-------------------------|-----------------|
| [mix_completions] archive | task names: `mix <TAB>`, `mix help <TAB>`    | `.mix_complete.cache`   | bash, zsh       |
| composer's script         | addresses: `mix composer.recipe.show <TAB>`  | `_build/composer/index` | bash, zsh, fish |

Composer's script **wraps** mix_completions. It registers last, completes
the arguments of composer's own tasks, and hands every other word to
mix_completions' function (`_mix_complete_complete` in bash, `_mix` in zsh).
Neither program starts the BEAM on Tab; each reads a plain-text file that an
earlier `mix` run wrote.

The scripts are the templates of the `cb_std:completions:composer` step,
in `lib/composer/cb_std/steps/completions/_composer/`, like any step's templates; the step copies
one into `~`. The
`cb_std/completions/install` recipe runs that step and
`cb_std:completions:mix`.

## The four completion types

| Type                | Example                            | Provider               | Reads                        |
|---------------------|------------------------------------|------------------------|------------------------------|
| command_completion  | `mix compo<TAB>` -> `composer.new` | mix_completions        | project or global task cache |
| composer_completion | `mix composer.<TAB>`               | mix_completions        | project task cache           |
| cookbook_completion | `mix composer.recipe.show <TAB>`   | composer's script      | `_build/composer/index`      |
| help_completion     | `mix help composer.rec<TAB>`       | mix_completions        | project task cache           |

### Task caches (command, composer and help completion)

A task cache has one `name<TAB>shortdoc` line per task.

- **Project cache**, `.mix_complete.cache`: used when both it and `mix.exs`
  exist. It lists archive tasks too (`composer.new`, `phx.new`).
- **Global cache**, `$XDG_CACHE_HOME/.mix_complete.cache` (default
  `~/.cache/.mix_complete.cache`): used everywhere else.
- **Writer:** `mix complete`, which writes the project cache in a project
  and the global cache outside one. `mix complete.bash` also writes the
  global cache as a side effect.
- **Stale when:** the project cache, after a deps change or a composer
  upgrade adds, removes or renames a task. The global cache, after an
  archive is installed, upgraded or removed. Neither is refreshed on its
  own.

### The index (cookbook completion)

- **File:** `_build/composer/index`, one `kind<TAB>canonical-id<TAB>text`
  line per entry, kind one of `self`, `cookbook`, `dir`, `chapter`,
  `recipe`, `group` or `step`. See `Composer.Index`.
- **Writer:** every composer task, as a side effect, and
  `mix composer.index` on request. It folds every cookbook's committed
  manifest (or, without one, its runtime metadata) into one file, so one
  generic script serves every project.
- **Stale when:** `mix.lock` is newer than the index, after a deps change.
  The script then offers no addresses until a composer task runs.
- **Used for:** the arguments of `composer.{step,recipe}.{run,show,help,edit}`
  and of `composer.recipe.list` and `composer.step.list`, when the word is
  at least the second argument and doesn't start with `-`. Completion goes
  one segment at a time: a bare word gives cookbook names and matching leaf
  names; `cb/` or `cb:` gives chapters, directories and groups (with no
  space after them); a leading `/` or `:` is the project's own cookbook
  (`self`); `step.run`'s comma lists complete their last item.

### help_completion needs mix_completions 0.4.1

mix_completions 0.3.0 completes task names only right after `mix`, so
`mix help comp<TAB>` offers nothing. The fix, [erikareads/mix_completions#2],
is in the generated shell function, not the cache, and was released in
0.4.1. The `cb_std:completions:mix` step replaces an older archive with the
Hex release. Composer's script passes `mix help ...` through unchanged
either way.

## Install order

The wrapper only works when composer's script registers after
mix_completions'.

- **bash:** source composer's script after mix_completions' script. With a
  `~/.complete/*.bash` glob, the default names do this:
  `mix_autocomplete.bash` sorts before `mix_composer.bash`.

  ```bash
  mix composer.recipe.run cb_std/completions/install
  ```

- **zsh:** put `_composer_mix` on `fpath` after mix_completions' `_mix`;
  it calls `_mix`, autoloading it if needed.

  ```bash
  mix composer.step.run cb_std:completions:composer -- --shell zsh
  ```

- **fish:** see below.

  ```bash
  mix composer.step.run cb_std:completions:composer -- --shell fish
  ```

## Stale-cache hints

The scripts check file times in the shell (`-nt`; no BEAM, no files
written) and print a one-line hint, at most once per shell session per
hint. A hint never changes the candidates.

| Hint                                                     | When                                                           |
|----------------------------------------------------------|----------------------------------------------------------------|
| `the completion index is stale; run mix composer.index` | `mix.lock` is newer than `_build/composer/index`               |
| `mix task completions are stale; run mix complete`      | in a project, `mix.lock` is newer than `.mix_complete.cache`  |
| `mix task completions are stale; run mix complete outside a project` | outside a project, `${MIX_HOME:-~/.mix}/archives` is newer than the global cache |

- bash prints hints on stderr, zsh shows them with `_message`, and fish has
  only the index hint, on stderr.
- A missing cache gives no hint: that user may not use mix_completions.
- The task-cache checks run only when mix_completions is loaded.
- The global hint also shows when the archives directory changes for
  another reason, such as a Hex update. Run `mix complete` outside a
  project once and it goes away.

## Fish

- mix_completions has no fish support. Fish ships its own
  `completions/mix.fish`, a fixed list of mix's built-in tasks, so fish
  completes those task names but not a project's or an archive's, and has
  no task-cache hints.
- Fish completions add up, so composer's script replaces nothing. It goes
  in `~/.config/fish/conf.d/`, which fish sources at startup, because fish
  autoloads only the first `mix.fish` on `fish_complete_path`: a
  user-level `~/.config/fish/completions/mix.fish` would hide fish's own.

## The contract

`Composer.Index` writes the index, and the awk program in
`lib/composer/cb_std/steps/completions/_composer/composer.{bash,zsh,fish}`
reads it. Both live in composer and are tested together:

- The awk program between the `# -- segments.awk --` markers must stay
  identical in the three scripts. A test checks this, and shell-specific
  logic (hints, delegation) stays outside the markers.
- Any change to the index lines needs a matching script change and test.
  `test/composer/completion_test.exs` completes against an index built with
  `Composer.Index.lines/1`, so format drift fails composer's own tests.
- The zsh and fish behaviour tests run only when those shells are
  installed.

[mix_completions]: https://hex.pm/packages/mix_completions
[erikareads/mix_completions#2]: https://github.com/erikareads/mix_completions/pull/2
