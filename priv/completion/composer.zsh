#compdef mix
# Zsh completion for composer's mix tasks, from `mix composer.completion zsh`.
#
# Completes step ids for `mix composer.step.{run,show,edit}`, recipe ids for
# `mix composer.recipe.{run,show,edit}`, and cookbook and chapter names
# (`cb_lab`, `cb_lab:lv/`) for `mix composer.recipe.list`, from
# _build/composer/index, without starting the BEAM, and hands every
# other `mix` completion to mix_completions' _mix
# (https://hex.pm/packages/mix_completions) when it is available.
#
# Save it on your fpath after mix_completions' _mix, e.g. as
# ~/.zsh/functions/_composer_mix, or source it after compinit.

__composer_index() {
  local index="_build/composer/index"
  [[ -f mix.exs && -f $index ]] || return 1

  if [[ -f mix.lock && mix.lock -nt $index ]]; then
    _message "composer: the completion index is stale; run mix composer.index"
    return 1
  fi

  print -r -- $index
}

_composer_mix() {
  local kind=""
  case ${words[2]} in
    composer.step.run|composer.step.show|composer.step.help|composer.step.edit) kind=step ;;
    composer.recipe.run|composer.recipe.show|composer.recipe.help|composer.recipe.edit) kind=recipe ;;
    composer.recipe.list) kind=list ;;
  esac

  if [[ -n $kind && $CURRENT -ge 3 && $PREFIX != -* ]]; then
    local index k id summary
    local -a ids chapters
    index=$(__composer_index) || return 1

    while IFS=$'\t' read -r k id summary; do
      # _describe splits "value:description" on ':', so escape the ':' in ids.
      if [[ $kind == list ]]; then
        [[ $k == cookbook ]] && ids+=("${id//:/\\:}:$summary")
        [[ $k == chapter ]] && chapters+=("${id//:/\\:}:$summary")
      elif [[ $k == $kind ]]; then
        ids+=("${id//:/\\:}:$summary")
      fi
    done < $index

    if [[ $kind == list ]]; then
      _describe -t cookbooks "composer cookbooks" ids
      # A chapter is completed further, so no space after it.
      _describe -t chapters "composer chapters" chapters -S ''
      return
    fi

    # step.run takes a comma-separated list: complete the last item.
    compset -P '*,'
    _describe -t ids "composer ${kind}s" ids
  elif (( $+functions[_mix] )) || autoload +X _mix 2>/dev/null; then
    _mix "$@"
  else
    _files
  fi
}

compdef _composer_mix mix
