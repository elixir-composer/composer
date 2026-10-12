# Bash completion for composer's mix tasks, from `mix composer.completion bash`.
#
# Completes step ids for `mix composer.step.{run,help}`, recipe ids for
# `mix composer.recipe.{run,show,edit}`, and cookbook and group names
# (`local`, `local:ash/`) for `mix composer.recipe.list`, from
# _build/composer/index, without starting the BEAM, and hands every
# other `mix` completion to mix_completions (https://hex.pm/packages/mix_completions)
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

# Completes the current argument from index lines of the given kinds
# (space-separated, e.g. "cookbook group").
__composer_complete_ids() {
  local kinds=" $1 " index
  index=$(__composer_index) || return 0

  # ':' is in COMP_WORDBREAKS, so "core:cr" arrives as three words. Rebuild
  # the whole argument from the line instead (ids never contain spaces).
  local line=${COMP_LINE:0:COMP_POINT}
  local full=${line##* }

  # step.run takes a comma-separated list: complete the last item.
  local before="" item=$full
  if [[ $full == *,* ]]; then
    before=${full%,*},
    item=${full##*,}
  fi

  local k id
  COMPREPLY=()
  while IFS=$'\t' read -r k id _; do
    [[ $kinds == *" $k "* && $id == "$item"* ]] && COMPREPLY+=("$before$id")
  done <"$index"

  # A group ("local:ash/") is completed further, so no space after it.
  if [[ ${#COMPREPLY[@]} -eq 1 && ${COMPREPLY[0]} == */ ]]; then
    compopt -o nospace 2>/dev/null
  fi

  # Bash replaces only the text after the last ':', so drop everything up to
  # it from each candidate (what bash-completion's __ltrim_colon_completions does).
  if [[ $full == *:* ]]; then
    local prefix=${full%"${full##*:}"}
    local i
    for i in "${!COMPREPLY[@]}"; do
      COMPREPLY[i]=${COMPREPLY[i]#"$prefix"}
    done
  fi
}

_composer_mix_complete() {
  local kind=""
  case ${COMP_WORDS[1]-} in
    composer.step.run | composer.step.help) kind=step ;;
    composer.recipe.run | composer.recipe.show | composer.recipe.edit) kind=recipe ;;
    composer.recipe.list) kind="cookbook group" ;;
  esac

  if [[ -n $kind && $COMP_CWORD -ge 2 && ${COMP_WORDS[COMP_CWORD]} != -* ]]; then
    __composer_complete_ids "$kind"
  elif declare -F _mix_complete_complete >/dev/null; then
    _mix_complete_complete "$@"
  else
    COMPREPLY=()
    compopt -o default 2>/dev/null
  fi
}

complete -F _composer_mix_complete mix
