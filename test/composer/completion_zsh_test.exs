defmodule Composer.CompletionZshTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  unless System.find_executable("zsh"), do: @moduletag(skip: "zsh is not installed")

  @script Path.expand("lib/composer/cb_std/steps/completions/_composer/composer.zsh")

  @index """
  self\tmine\t
  cookbook\tcb_std\tBuilt-in steps
  cookbook\tmine\tYour recipes
  chapter\tmine/ash/\t1 recipe
  chapter\tmine/lv/\t1 recipe
  recipe\tmine/ash/core\tAsh core
  recipe\tmine/lv/base\tMy LiveView
  group\tcb_std:setup:\t1 step
  step\tcb_std:setup:credo\tAdds Credo
  step\tcb_std:tidy\tTidies
  """

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "mix.exs"), "")
    File.write!(Path.join(dir, "mix.lock"), "")
    File.mkdir_p!(Path.join(dir, "_build/composer"))
    # Newer than mix.lock, so the index is fresh.
    File.write!(Path.join(dir, "_build/composer/index"), @index)
    File.touch!(Path.join(dir, "mix.lock"), System.os_time(:second) - 60)
    :ok
  end

  # Calls _composer_mix once per line, in one zsh process, with the
  # completion builtins stubbed, and returns one list per line of
  # {:add, candidate, nospace?}, {:message, text} and :delegated. compinit
  # never runs.
  defp session(dir, lines) do
    script = """
    compdef() { : }
    compadd() {
      local nospace=0
      while [[ $1 != -- ]]; do
        case $1 in
          -S) [[ -z $2 ]] && nospace=1; shift ;;
          -d) shift ;;
        esac
        shift
      done
      shift
      local c
      for c in "$@"; do print -r -- "add\t$nospace\t$c"; done
    }
    _message() { print -r -- "message\t$*" }
    compset() {
      if [[ $1 == -P && $2 == '*,' && $PREFIX == *,* ]]; then
        IPREFIX=${PREFIX%,*},
        PREFIX=${PREFIX##*,}
      fi
      return 0
    }
    _mix() { print -r -- delegated }
    source #{@script}
    #{Enum.map_join(lines, "\n", &tab/1)}
    """

    {output, 0} = System.cmd("zsh", ["-f", "-c", script], cd: dir)

    output
    |> String.split("<end>\n")
    |> Enum.drop(-1)
    |> Enum.map(fn out ->
      for line <- String.split(out, "\n", trim: true) do
        case String.split(line, "\t") do
          ["add", nospace, candidate] -> {:add, candidate, nospace == "1"}
          ["message", text] -> {:message, text}
          ["delegated"] -> :delegated
        end
      end
    end)
  end

  defp tab(line) do
    words = String.split(line, " ")

    """
    words=(#{Enum.map_join(words, " ", &shell_quote/1)})
    CURRENT=#{length(words)}
    PREFIX=#{shell_quote(List.last(words))}
    IPREFIX=
    _composer_mix
    print '<end>'
    """
  end

  defp shell_quote(word), do: "'" <> String.replace(word, "'", ~S('\'')) <> "'"

  test "a step segment: groups with no suffix, steps with one", %{tmp_dir: dir} do
    assert session(dir, ["mix composer.step.run cb_std:"]) == [
             [{:add, "cb_std:setup:", true}, {:add, "cb_std:tidy", false}]
           ]

    # step.run completes the last item of a comma-separated list.
    assert session(dir, ["mix composer.step.run cb_std:tidy,cb_std:setup:"]) == [
             [{:add, "cb_std:setup:credo", false}]
           ]
  end

  test "a recipe segment", %{tmp_dir: dir} do
    assert session(dir, ["mix composer.recipe.show mine/"]) == [
             [{:add, "mine/ash/", true}, {:add, "mine/lv/", true}]
           ]

    assert session(dir, ["mix composer.recipe.run mine/lv/"]) == [
             [{:add, "mine/lv/base", false}]
           ]
  end

  test "everything else goes to mix_completions' _mix", %{tmp_dir: dir} do
    assert session(dir, ["mix comp", "mix help composer.rec", "mix composer.step.run --d"]) ==
             [[:delegated], [:delegated], [:delegated]]
  end

  test "a stale index offers nothing, with one message per session", %{tmp_dir: dir} do
    File.touch!(Path.join(dir, "mix.lock"))
    File.touch!(Path.join(dir, "_build/composer/index"), System.os_time(:second) - 60)

    assert session(dir, ["mix composer.step.run cb", "mix composer.recipe.run m"]) == [
             [{:message, "composer: the completion index is stale; run mix composer.index"}],
             []
           ]
  end

  test "a task cache older than mix.lock: one message, still delegated", %{tmp_dir: dir} do
    File.write!(Path.join(dir, ".mix_complete.cache"), "")
    File.touch!(Path.join(dir, ".mix_complete.cache"), System.os_time(:second) - 120)

    assert session(dir, ["mix comp", "mix comp"]) == [
             [
               {:message, "composer: mix task completions are stale; run mix complete"},
               :delegated
             ],
             [:delegated]
           ]
  end
end
