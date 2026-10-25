# Bash completion for composer's mix tasks, from `mix composer.completion bash`.
#
# Completes addresses one segment at a time, from _build/composer/index,
# without starting the BEAM: steps (cb_std:setup:credo) for
# `mix composer.step.{run,show,help,edit}`, recipes (cb_lab/lv/base) for
# `mix composer.recipe.{run,show,help,edit}`, and listing stems (cb_lab/,
# cb_std:cluster:) for `mix composer.recipe.list` and `mix composer.step.list`.
# A bare word completes to cookbook names and to the recipes or steps it
# names; a leading / or : is the project's own cookbook. Every other `mix`
# completion goes to mix_completions (https://hex.pm/packages/mix_completions)
# when it is loaded. Source this file after mix_completions' script.

# Prints the index path, or fails when it is missing or older than mix.lock.
__composer_index() {
  local index="_build/composer/index"
  [[ -f mix.exs && -f $index ]] || return 1

  if [[ -f mix.lock && mix.lock -nt $index ]]; then
    if [[ -z ${__composer_stale_hinted-} ]]; then
      __composer_stale_hinted=1
      printf '\n(composer: the completion index is stale; run mix composer.index)\n' >&2
    fi
    return 1
  fi

  printf '%s\n' "$index"
}

# The same program is in composer.zsh and composer.fish.
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

# Completes the current argument in MODE (recipe, step, rlist or slist).
__composer_complete() {
  local mode=$1 index
  COMPREPLY=()
  # A word starting with / or . never falls back to filenames.
  compopt +o default 2>/dev/null
  index=$(__composer_index) || return 0

  # ':' is in COMP_WORDBREAKS, so "cb_std:setup:cr" arrives as several words.
  # Rebuild the whole argument from the line instead (ids never contain spaces).
  local line=${COMP_LINE:0:COMP_POINT}
  local full=${line##* }

  # step.run takes a comma-separated list: complete the last item.
  local before="" item=$full
  if [[ $mode == step && $full == *,* ]]; then
    before=${full%,*},
    item=${full##*,}
  fi

  local nospace candidate all=1
  while IFS=$'\t' read -r nospace candidate _; do
    COMPREPLY+=("$before$candidate")
    [[ $nospace == 1 ]] || all=0
  done < <(awk -v MODE="$mode" -v ITEM="$item" "$__composer_awk" "$index")

  # A chapter, directory, group or cookbook name is completed further, so no
  # space after it.
  if [[ ${#COMPREPLY[@]} -gt 0 && $all == 1 ]]; then
    compopt -o nospace 2>/dev/null
  fi

  # Bash replaces only the text after the last ':', so drop everything up to
  # it from each candidate (what bash-completion's __ltrim_colon_completions
  # does), however many ':' the word has.
  if [[ $full == *:* ]]; then
    local prefix=${full%"${full##*:}"}
    local i
    for i in "${!COMPREPLY[@]}"; do
      COMPREPLY[i]=${COMPREPLY[i]#"$prefix"}
    done
  fi
}

_composer_mix_complete() {
  local mode=""
  case ${COMP_WORDS[1]-} in
    composer.step.run | composer.step.show | composer.step.help | composer.step.edit) mode=step ;;
    composer.recipe.run | composer.recipe.show | composer.recipe.help | composer.recipe.edit) mode=recipe ;;
    composer.recipe.list) mode=rlist ;;
    composer.step.list) mode=slist ;;
  esac

  if [[ -n $mode && $COMP_CWORD -ge 2 && ${COMP_WORDS[COMP_CWORD]} != -* ]]; then
    __composer_complete "$mode"
  elif declare -F _mix_complete_complete >/dev/null; then
    _mix_complete_complete "$@"
  else
    COMPREPLY=()
    compopt -o default 2>/dev/null
  fi
}

complete -F _composer_mix_complete mix
