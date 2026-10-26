# Fish completion for composer's mix tasks, installed by `cb_std:completions:composer`.
#
# Completes addresses one segment at a time, from _build/composer/index,
# without starting the BEAM: steps (cb_std:setup:credo) for
# `mix composer.step.{run,show,help,edit}`, recipes (cb_lab/lv/base) for
# `mix composer.recipe.{run,show,help,edit}`, and listing stems (cb_lab/,
# cb_std:cluster:) for `mix composer.recipe.list` and `mix composer.step.list`.
# A bare word completes to cookbook names and to the recipes or steps it
# names; a leading / or : is the project's own cookbook. Fish completions
# add up, so other `mix` completions are untouched. Save it as
# ~/.config/fish/conf.d/composer_mix.fish, not as completions/mix.fish,
# which would hide the mix.fish that fish ships.
#
# Hints once per session, on stderr, when the index is older than mix.lock.

function __composer_index
    set -l index _build/composer/index
    test -f mix.exs; and test -f $index; or return 1

    if test -f mix.lock; and command test mix.lock -nt $index
        if not set -q __composer_stale_hinted
            set -g __composer_stale_hinted 1
            printf '\n(composer: the completion index is stale; run mix composer.index)\n' >&2
        end
        return 1
    end

    echo $index
end

# The same program is in composer.bash and composer.zsh.
# -- segments.awk --
set -g __composer_awk '
# Prints the completion candidates for ITEM, one segment at a time, as
# "nospace<TAB>candidate<TAB>description", nospace 1 after a chapter,
# directory, group or cookbook name. MODE is recipe, step,
# rlist (recipe.list stems) or slist (step.list stems).
BEGIN { FS = "\t" }
$1 == "self" { own = $2; next }
{ n++; kind[n] = $1; id[n] = $2; text[n] = $3 }
END {
  item = ITEM
  sep = (MODE == "recipe" || MODE == "rlist") ? "/" : ":"
  first = substr(item, 1, 1)
  if (first == ".") exit
  root = 0
  if (first == "/" || first == ":") {
    if (first != sep || own == "") exit
    root = 1
    item = own item
  }

  if (index(item, "/") == 0 && index(item, ":") == 0) {
    for (i = 1; i <= n; i++) {
      if (kind[i] == "cookbook" && substr(id[i], 1, length(item)) == item) emit(id[i], text[i], 1)
    }
    if (MODE == "recipe" || MODE == "step") {
      for (i = 1; i <= n; i++) {
        if (kind[i] != MODE) continue
        leaf = id[i]
        sub(/.*[\/:]/, "", leaf)
        if (substr(leaf, 1, length(item)) == item) emit(leaf, id[i], 0)
      }
    }
    exit
  }

  if (MODE == "recipe") wanted = " recipe chapter dir "
  else if (MODE == "rlist") wanted = " chapter dir "
  else if (MODE == "step") wanted = " step group "
  else wanted = " group "

  # The item up to its last separator, and the cookbook part.
  p = item
  sub(/[^\/:]*$/, "", p)
  if (substr(p, length(p), 1) != sep) exit
  for (i = 1; i <= n; i++) {
    if (index(wanted, " " kind[i] " ") == 0) continue
    if (substr(id[i], 1, length(item)) != item) continue
    rest = substr(id[i], length(p) + 1)
    if (rest == "") continue
    j = index(rest, sep)
    if (j > 0) emit(p substr(rest, 1, j), "", 1)
    else emit(p rest, text[i], 0)
  }
}

function emit(candidate, description, nospace) {
  if (root) candidate = substr(candidate, length(own) + 1)
  if (candidate in seen || candidate == "") return
  seen[candidate] = 1
  printf "%d\t%s\t%s\n", nospace, candidate, description
}
'
# -- end segments.awk --

function __composer_complete --argument-names mode
    set -l index (__composer_index); or return 0
    set -l token (commandline -ct)
    set -l before ""

    # step.run takes a comma-separated list: complete the last item.
    if test $mode = step; and string match -q -- '*,*' $token
        set before (string replace -r -- '[^,]*$' '' $token)
        set token (string replace -r -- '^.*,' '' $token)
    end

    # Fish adds no space after a candidate ending in / or :.
    awk -v MODE=$mode -v ITEM="$token" $__composer_awk $index | while read -l -d \t nospace candidate description
        printf '%s%s\t%s\n' $before $candidate $description
    end
end

complete -c mix -f -n '__fish_seen_subcommand_from composer.step.run composer.step.show composer.step.help composer.step.edit' -a '(__composer_complete step)'
complete -c mix -f -n '__fish_seen_subcommand_from composer.recipe.run composer.recipe.show composer.recipe.help composer.recipe.edit' -a '(__composer_complete recipe)'
complete -c mix -f -n '__fish_seen_subcommand_from composer.recipe.list' -a '(__composer_complete rlist)'
complete -c mix -f -n '__fish_seen_subcommand_from composer.step.list' -a '(__composer_complete slist)'
