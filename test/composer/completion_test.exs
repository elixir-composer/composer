defmodule Composer.CompletionTest do
  use ExUnit.Case, async: true

  alias Composer.Index

  @moduletag :tmp_dir

  unless System.find_executable("bash"), do: @moduletag(skip: "bash is not installed")

  @script Path.expand("lib/composer/cb_std/steps/completions/_composer/composer.bash")

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
  # and returns {COMPREPLY, nospace?, default?}.
  defp complete(dir, line) do
    {[result], _stderr} = session(dir, [line])
    result
  end

  # Completes each of `lines` in turn, in one bash process, and returns
  # {[{COMPREPLY, nospace?, default?}], stderr}. compopt is stubbed, since it
  # only works inside a real completion.
  defp session(dir, lines, env \\ []) do
    stderr = Path.join(dir, ".stderr")

    script = """
    source #{@script}
    compopt() { [[ $* == "-o nospace" ]] && __nospace=1; [[ $* == "-o default" ]] && __default=1; return 0; }
    _mix_complete_complete() { COMPREPLY=(delegated); }
    #{Enum.map_join(lines, "\n", &tab(&1, stderr))}
    """

    {output, 0} = System.cmd("bash", ["-c", script], cd: dir, env: env)

    results =
      output
      |> String.split("<end>\n")
      |> Enum.drop(-1)
      |> Enum.map(fn out ->
        out = String.split(out, "\n", trim: true)
        {out -- ["<nospace>", "<default>"], "<nospace>" in out, "<default>" in out}
      end)

    {results, if(File.exists?(stderr), do: File.read!(stderr), else: "")}
  end

  defp tab(line, stderr) do
    words = line |> String.split(~r/(?<=:)|(?=:)| /) |> Enum.reject(&(&1 == ""))
    words = if String.ends_with?(line, " "), do: words ++ [""], else: words

    """
    __nospace= __default= COMPREPLY=()
    COMP_LINE=#{shell_quote(line)}
    COMP_POINT=${#COMP_LINE}
    COMP_WORDS=(#{Enum.map_join(words, " ", &shell_quote/1)})
    COMP_CWORD=#{length(words) - 1}
    _composer_mix_complete mix 2>>#{shell_quote(stderr)}
    printf '%s\\n' "${COMPREPLY[@]}"
    [[ -n $__nospace ]] && echo '<nospace>'
    [[ -n $__default ]] && echo '<default>'
    echo '<end>'
    """
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

  test "offers nothing when the index is older than mix.lock, and hints once", %{tmp_dir: dir} do
    File.touch!(Path.join(dir, "mix.lock"))
    File.touch!(Path.join(dir, "_build/composer/index"), System.os_time(:second) - 60)

    lines = ["mix composer.step.run co", "mix composer.recipe.run m"]
    assert {[{[], false, false}, {[], false, false}], stderr} = session(dir, lines)
    assert hints(stderr) == ["(composer: the completion index is stale; run mix composer.index)"]
  end

  test "everything else is delegated to mix_completions", %{tmp_dir: dir} do
    assert candidates(dir, "mix comp") == ["delegated"]
    assert candidates(dir, "mix composer.step.run --dr") == ["delegated"]
    assert candidates(dir, "mix help composer.rec") == ["delegated"]
  end

  describe "mix_completions' task cache" do
    test "older than mix.lock: hints once, and still delegates", %{tmp_dir: dir} do
      File.write!(Path.join(dir, ".mix_complete.cache"), "")
      File.touch!(Path.join(dir, ".mix_complete.cache"), System.os_time(:second) - 120)

      assert {[{["delegated"], _, _}, {["delegated"], _, _}], stderr} =
               session(dir, ["mix comp", "mix help comp"])

      assert hints(stderr) == ["(composer: mix task completions are stale; run mix complete)"]
    end

    test "fresh or missing: no hint", %{tmp_dir: dir} do
      assert {[{["delegated"], _, _}], ""} = session(dir, ["mix comp"])

      File.write!(Path.join(dir, ".mix_complete.cache"), "")
      assert {[{["delegated"], _, _}], ""} = session(dir, ["mix comp"])
    end

    test "outside a project, the global cache older than the archives: hints once", %{
      tmp_dir: dir
    } do
      elsewhere = Path.join(dir, "elsewhere")
      mix_home = Path.join(dir, "mix_home")
      cache_home = Path.join(dir, "cache")
      File.mkdir_p!(elsewhere)
      File.mkdir_p!(Path.join(mix_home, "archives"))
      File.mkdir_p!(cache_home)
      File.write!(Path.join(cache_home, ".mix_complete.cache"), "")
      File.touch!(Path.join(cache_home, ".mix_complete.cache"), System.os_time(:second) - 120)

      env = [{"MIX_HOME", mix_home}, {"XDG_CACHE_HOME", cache_home}]

      assert {[{["delegated"], _, _}, {["delegated"], _, _}], stderr} =
               session(elsewhere, ["mix comp", "mix comp"], env)

      assert hints(stderr) == [
               "(composer: mix task completions are stale; run mix complete outside a project)"
             ]

      # A fresh global cache: no hint.
      File.touch!(Path.join(cache_home, ".mix_complete.cache"))
      File.touch!(Path.join(mix_home, "archives"), System.os_time(:second) - 120)
      File.rm!(Path.join(elsewhere, ".stderr"))
      assert {[{["delegated"], _, _}], ""} = session(elsewhere, ["mix comp"], env)
    end
  end

  test "the bash, zsh and fish scripts share one segment program" do
    programs =
      for shell <- ~w(bash zsh fish) do
        source = File.read!("lib/composer/cb_std/steps/completions/_composer/composer.#{shell}")
        [_, program, _] = String.split(source, ~r/# -- (end )?segments.awk --\n/)
        program |> String.split("\n") |> Enum.drop(1) |> Enum.drop(-2)
      end

    assert [same, same, same] = programs
  end

  describe "the index Composer.Index writes" do
    # cb_std has a committed manifest and step groups, fake_book has none,
    # and nested_book has nested chapters. Run from composer, so cb_std is
    # the project's own cookbook.
    setup %{tmp_dir: dir} do
      cookbooks =
        Enum.map([Composer.CbStd, Composer.FakeBook, Composer.NestedBook], &from_module/1)

      lines = Index.lines(cookbooks)
      File.write!(Path.join(dir, "_build/composer/index"), Enum.map(lines, &[&1, "\n"]))
      %{entries: Enum.map(lines, &String.split(&1, "\t"))}
    end

    test "a step segment", %{tmp_dir: dir, entries: entries} do
      expected = next_segments(entries, ~w(step group), "fake_book:", ":")
      assert expected != []

      # Bash replaces only what follows the last ':'.
      assert Enum.sort(candidates(dir, "mix composer.step.run fake_book:")) ==
               Enum.map(expected, &String.replace_prefix(&1, "fake_book:", ""))
    end

    test "a recipe segment", %{tmp_dir: dir, entries: entries} do
      expected = next_segments(entries, ~w(recipe chapter dir), "nested_book/ash/", "/")
      assert expected != []
      assert Enum.sort(candidates(dir, "mix composer.recipe.run nested_book/ash/")) == expected
    end

    test "a root address is the self cookbook", %{tmp_dir: dir, entries: entries} do
      assert ["self", own, _] = Enum.find(entries, &(hd(&1) == "self"))
      expected = next_segments(entries, ~w(step group), own <> ":", ":")
      assert expected != []

      assert Enum.sort(candidates(dir, "mix composer.step.run :")) ==
               Enum.map(expected, &String.replace_prefix(&1, own <> ":", ""))
    end
  end

  defp from_module(module), do: Composer.Cookbook.from_module(module)

  # The candidates that follow `prefix` in the index entries of `kinds`: the
  # next segment, ending in `sep` when more segments follow.
  defp next_segments(entries, kinds, prefix, sep) do
    for [kind, id | _] <- entries,
        kind in kinds,
        rest = String.replace_prefix(id, prefix, ""),
        rest != id and rest != "",
        uniq: true do
      case String.split(rest, sep, parts: 2) do
        [segment, _] -> prefix <> segment <> sep
        [segment] -> prefix <> segment
      end
    end
    |> Enum.sort()
  end

  defp hints(stderr), do: String.split(stderr, "\n", trim: true)
end
