defmodule Composer.CompletionTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  unless System.find_executable("bash"), do: @moduletag(skip: "bash is not installed")

  @script Path.expand("priv/completion/composer.bash")

  @index """
  self\tmine\t
  cookbook\tcc_lab\tAndy's steps
  cookbook\tcb_std\tBuilt-in steps
  cookbook\tmine\tYour recipes
  chapter\tcc_lab/lv/\t1 recipe
  chapter\tmine/ash/\t1 recipe
  dir\tmine/ash/\t1 chapter, 1 directory
  chapter\tmine/ash/ui/\t2 recipes
  chapter\tmine/lv/\t1 recipe
  recipe\tcc_lab/lv/base\tLiveView base
  recipe\tmine/ash/core\tAsh core
  recipe\tmine/ash/ui/buttons\tButtons
  recipe\tmine/ash/ui/forms\tForms
  recipe\tmine/lv/base\tMy LiveView
  group\tcb_std:cluster:\t3 steps
  group\tcb_std:cluster:gigalixir:\t1 step
  group\tcb_std:setup:\t1 step
  step\tcc_lab:ash\tAdds Ash
  step\tcb_std:cluster:gigalixir\tGigalixir
  step\tcb_std:cluster:gigalixir:libcluster\tGigalixir libcluster
  step\tcb_std:cluster:libcluster\tlibcluster
  step\tcb_std:setup:credo\tAdds Credo
  group\tmine:tools:\t1 step
  step\tmine:tools:thing\tA thing
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

  # Completes `line` the way bash would split it, with ':' as a word break,
  # and returns {COMPREPLY, nospace?}. compopt is stubbed, since it only
  # works inside a real completion.
  defp complete(dir, line) do
    words = line |> String.split(~r/(?<=:)|(?=:)| /) |> Enum.reject(&(&1 == ""))
    words = if String.ends_with?(line, " "), do: words ++ [""], else: words

    script = """
    source #{@script}
    compopt() { [[ $* == "-o nospace" ]] && __nospace=1; [[ $* == "-o default" ]] && __default=1; return 0; }
    _mix_complete_complete() { COMPREPLY=(delegated); }
    COMP_LINE=#{shell_quote(line)}
    COMP_POINT=${#COMP_LINE}
    COMP_WORDS=(#{Enum.map_join(words, " ", &shell_quote/1)})
    COMP_CWORD=#{length(words) - 1}
    _composer_mix_complete mix
    printf '%s\\n' "${COMPREPLY[@]}"
    [[ -n ${__nospace-} ]] && echo '<nospace>'
    [[ -n ${__default-} ]] && echo '<default>'
    true
    """

    {output, 0} = System.cmd("bash", ["-c", script], cd: dir, stderr_to_stdout: true)
    lines = String.split(output, "\n", trim: true)
    {lines -- ["<nospace>", "<default>"], "<nospace>" in lines, "<default>" in lines}
  end

  defp candidates(dir, line), do: elem(complete(dir, line), 0)

  defp shell_quote(word), do: "'" <> String.replace(word, "'", ~S('\'')) <> "'"

  test "a bare word: cookbook names, with no space, and the steps it names", %{tmp_dir: dir} do
    assert complete(dir, "mix composer.step.run cc") == {["cc_lab"], true, false}
    assert candidates(dir, "mix composer.step.run c") == ["cc_lab", "cb_std", "credo"]
    assert candidates(dir, "mix composer.step.run cred") == ["credo"]
    assert candidates(dir, "mix composer.step.run libc") == ["libcluster"]
    assert candidates(dir, "mix composer.recipe.run bu") == ["buttons"]
  end

  test "steps complete one segment at a time, with no space after a group", %{tmp_dir: dir} do
    assert complete(dir, "mix composer.step.run cb_std:") == {["cluster:", "setup:"], true, false}
    assert complete(dir, "mix composer.step.run cb_std:cl") == {["cluster:"], true, false}

    # Bash replaces only what follows the last ':', however many there are.
    assert complete(dir, "mix composer.step.run cb_std:cluster:") ==
             {["gigalixir:", "gigalixir", "libcluster"], false, false}

    assert complete(dir, "mix composer.step.run cb_std:cluster:gigalixir:") ==
             {["libcluster"], false, false}

    assert complete(dir, "mix composer.step.show cb_std:cluster:gigalixir:l") ==
             {["libcluster"], false, false}
  end

  test "recipes complete one segment at a time, chapter and directory alike", %{tmp_dir: dir} do
    assert complete(dir, "mix composer.recipe.run mine/") ==
             {["mine/ash/", "mine/lv/"], true, false}

    assert candidates(dir, "mix composer.recipe.show mine/ash/") ==
             ["mine/ash/ui/", "mine/ash/core"]

    assert complete(dir, "mix composer.recipe.edit mine/ash/ui/") ==
             {["mine/ash/ui/buttons", "mine/ash/ui/forms"], false, false}
  end

  test "/ and : are the project's own cookbook", %{tmp_dir: dir} do
    assert candidates(dir, "mix composer.recipe.run /") == ["/ash/", "/lv/"]
    assert candidates(dir, "mix composer.recipe.run /ash/u") == ["/ash/ui/"]
    assert candidates(dir, "mix composer.step.run :") == ["tools:"]
    assert candidates(dir, "mix composer.step.run :tools:") == ["thing"]
  end

  test "a word starting with / or . never falls back to filenames", %{tmp_dir: dir} do
    assert complete(dir, "mix composer.recipe.run /usr") == {[], false, false}
    assert complete(dir, "mix composer.recipe.run ./") == {[], false, false}
    assert complete(dir, "mix composer.recipe.run ../x") == {[], false, false}
    # A step task has no / addresses.
    assert complete(dir, "mix composer.step.run /") == {[], false, false}
  end

  test "completes the last item of a comma-separated list", %{tmp_dir: dir} do
    assert candidates(dir, "mix composer.step.run cb_std:setup:credo,cb_std:cluster:gigalixir:") ==
             ["libcluster"]

    # Together with the "cc_lab:" bash already has, this is "cc_lab:ash,credo".
    assert candidates(dir, "mix composer.step.run cc_lab:ash,cred") == ["ash,credo"]
  end

  test "the listing tasks complete stems", %{tmp_dir: dir} do
    assert complete(dir, "mix composer.recipe.list mi") == {["mine"], true, false}

    assert complete(dir, "mix composer.recipe.list mine/") ==
             {["mine/ash/", "mine/lv/"], true, false}

    assert candidates(dir, "mix composer.recipe.list mine cc_lab/") == ["cc_lab/lv/"]
    assert candidates(dir, "mix composer.step.list cb_std:") == ["cluster:", "setup:"]
    assert candidates(dir, "mix composer.step.list cb_std:cluster:") == ["gigalixir:"]
  end

  test "offers nothing when the index is older than mix.lock", %{tmp_dir: dir} do
    File.touch!(Path.join(dir, "mix.lock"))
    File.touch!(Path.join(dir, "_build/composer/index"), System.os_time(:second) - 60)
    assert Enum.reject(candidates(dir, "mix composer.step.run co"), &(&1 =~ "stale")) == []
  end

  test "everything else is delegated to mix_completions", %{tmp_dir: dir} do
    assert candidates(dir, "mix comp") == ["delegated"]
    assert candidates(dir, "mix composer.step.run --dr") == ["delegated"]
  end

  test "the bash, zsh and fish scripts share one segment program" do
    programs =
      for shell <- ~w(bash zsh fish) do
        source = File.read!("priv/completion/composer.#{shell}")
        [_, program, _] = String.split(source, ~r/# -- (end )?segments.awk --\n/)
        program |> String.split("\n") |> Enum.drop(1) |> Enum.drop(-2)
      end

    assert [same, same, same] = programs
  end
end
