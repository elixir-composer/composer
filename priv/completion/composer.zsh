#compdef mix
# Zsh completion for composer's mix tasks, installed by `cb_std:completions:composer`.
#
# Completes addresses one segment at a time, from _build/composer/index,
# without starting the BEAM: steps (cb_std:setup:credo) for
# `mix composer.step.{run,show,help,edit}`, recipes (cb_lab/lv/base) for
# `mix composer.recipe.{run,show,help,edit}`, and listing stems (cb_lab/,
# cb_std:cluster:) for `mix composer.recipe.list` and `mix composer.step.list`.
# A bare word completes to cookbook names and to the recipes or steps it
# names; a leading / or : is the project's own cookbook. Every other `mix`
# completion goes to mix_completions' _mix
# (https://hex.pm/packages/mix_completions) when it is available.
#
# Save it on your fpath after mix_completions' _mix, e.g. as
# ~/.zsh/functions/_composer_mix, or source it after compinit.
#
# Hints once per session, as a completion message, when the index is older
# than mix.lock or mix_completions' task cache is stale.

# Shows "composer: MESSAGE" once per session for each KEY.
__composer_hint() {
  local guard=__composer_hinted_$1
  [[ -n ${(P)guard} ]] && return 0
  typeset -g $guard=1
  _message "composer: $2"
}

# Sets the caller's `index` to the index path, or fails when it is missing
# or older than mix.lock. Not run in a subshell, so the message is shown.
__composer_index() {
  index="_build/composer/index"
  [[ -f mix.exs && -f $index ]] || return 1

  if [[ -f mix.lock && mix.lock -nt $index ]]; then
    __composer_hint index "the completion index is stale; run mix composer.index"
    return 1
  fi
}

# Hints when mix_completions' task cache is stale: in a project, older than
# mix.lock; elsewhere, the global cache older than the archives directory.
# A missing cache gives no hint.
__composer_mix_cache_check() {
  if [[ -f mix.exs ]]; then
    if [[ -f .mix_complete.cache && -f mix.lock && mix.lock -nt .mix_complete.cache ]]; then
      __composer_hint project_cache "mix task completions are stale; run mix complete"
    fi
  else
    local archives=${MIX_HOME:-$HOME/.mix}/archives
    local cache=${XDG_CACHE_HOME:-$HOME/.cache}/.mix_complete.cache
    if [[ -e $archives && -f $cache && $archives -nt $cache ]]; then
      __composer_hint global_cache "mix task completions are stale; run mix complete outside a project"
    fi
  fi
}

# The same program is in composer.bash and composer.fish.
# -- segments.awk --
__composer_awk='
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

_composer_mix() {
  local mode=""
  case ${words[2]} in
    composer.step.run|composer.step.show|composer.step.help|composer.step.edit) mode=step ;;
    composer.recipe.run|composer.recipe.show|composer.recipe.help|composer.recipe.edit) mode=recipe ;;
    composer.recipe.list) mode=rlist ;;
    composer.step.list) mode=slist ;;
  esac

  if [[ -n $mode && $CURRENT -ge 3 && $PREFIX != -* ]]; then
    local index nospace candidate description
    local -a spaced spaced_d stems stems_d
    __composer_index || return 1

    # step.run takes a comma-separated list: complete the last item.
    [[ $mode == step ]] && compset -P '*,'

    while IFS=$'\t' read -r nospace candidate description; do
      if [[ $nospace == 1 ]]; then
        stems+=($candidate)
        stems_d+=("$candidate")
      else
        spaced+=($candidate)
        spaced_d+=("$candidate${description:+  -- $description}")
      fi
    done < <(awk -v MODE="$mode" -v ITEM="$PREFIX" "$__composer_awk" $index)

    # A chapter, directory, group or cookbook name is completed further, so
    # no space after it. A word starting with / or . never completes files.
    (( $#stems )) && compadd -Q -S '' -d stems_d -- $stems
    (( $#spaced )) && compadd -Q -l -d spaced_d -- $spaced
    return 0
  elif (( $+functions[_mix] )) || autoload +X _mix 2>/dev/null; then
    __composer_mix_cache_check
    _mix "$@"
  else
    _files
  fi
}

compdef _composer_mix mix
