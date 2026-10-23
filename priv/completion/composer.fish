# Fish completion for composer's mix tasks, from `mix composer.completion fish`.
#
# Completes step ids for `mix composer.step.{run,show,edit}`, recipe ids for
# `mix composer.recipe.{run,show,edit}`, and cookbook and group names
# (`cb_lab`, `cb_lab:lv/`) for `mix composer.recipe.list`, from
# _build/composer/index, without starting the BEAM. Fish completions
# add up, so other `mix` completions are untouched. Save it as
# ~/.config/fish/completions/mix.fish, or source it from there.

function __composer_index
    set -l index _build/composer/index
    test -f mix.exs; and test -f $index; or return 1

    if test -f mix.lock; and command test mix.lock -nt $index
        return 1
    end

    echo $index
end

function __composer_ids --argument-names kind
    set -l index (__composer_index); or return 0
    string match -r -- "^$kind\t.*" <$index | string replace -r -- "^$kind\t([^\t]*)\t?(.*)" '$1\t$2'
end

complete -c mix -f -n '__fish_seen_subcommand_from composer.step.run composer.step.show composer.step.help composer.step.edit' -a '(__composer_ids step)'
complete -c mix -f -n '__fish_seen_subcommand_from composer.recipe.run composer.recipe.show composer.recipe.help composer.recipe.edit' -a '(__composer_ids recipe)'
complete -c mix -f -n '__fish_seen_subcommand_from composer.recipe.list' -a '(__composer_ids cookbook; __composer_ids group)'
