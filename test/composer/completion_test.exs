defmodule Composer.CompletionTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  unless System.find_executable("bash"), do: @moduletag(skip: "bash is not installed")

  @script Path.expand("priv/completion/composer.bash")

  @index """
  group\tcc_lab:lv/\t1 recipe
  group\tlocal:ash/\t2 recipes
  group\tlocal:lv/\t1 recipe
  recipe\tcc_lab:lv/base\tLiveView base
  recipe\tlocal:ash/auth\tAsh with auth
  recipe\tlocal:ash/base\tAsh core
  recipe\tlocal:lv/base\tMy LiveView
  cookbook\tcc_lab\tAndy's steps
  cookbook\tcore\tBuilt-in steps
  cookbook\tlocal\tYour recipes
  step\tcc_lab:ash\tAdds Ash
  step\tcc_lab:ash/postgres\tAdds AshPostgres
  step\tcore:setup/credo\tAdds Credo
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
  # and returns COMPREPLY.
  defp complete(dir, line) do
    words = line |> String.split(~r/(?<=:)|(?=:)| /) |> Enum.reject(&(&1 == ""))
    words = if String.ends_with?(line, " "), do: words ++ [""], else: words

    script = """
    source #{@script}
    _mix_complete_complete() { COMPREPLY=(delegated); }
    COMP_LINE=#{shell_quote(line)}
    COMP_POINT=${#COMP_LINE}
    COMP_WORDS=(#{Enum.map_join(words, " ", &shell_quote/1)})
    COMP_CWORD=#{length(words) - 1}
    _composer_mix_complete mix
    printf '%s\\n' "${COMPREPLY[@]}"
    """

    {output, 0} = System.cmd("bash", ["-c", script], cd: dir, stderr_to_stdout: true)
    String.split(output, "\n", trim: true)
  end

  defp shell_quote(word), do: "'" <> String.replace(word, "'", ~S('\'')) <> "'"

  test "completes ids, trimming what bash already has before the last ':'", %{tmp_dir: dir} do
    assert complete(dir, "mix composer.step.run cc_lab:a") == ["ash", "ash/postgres"]

    assert complete(dir, "mix composer.step.edit cc_lab:ash/") == ["ash/postgres"]
    assert complete(dir, "mix composer.step.help cc_lab:ash/") == ["ash/postgres"]

    assert complete(dir, "mix composer.step.show c") == [
             "cc_lab:ash",
             "cc_lab:ash/postgres",
             "core:setup/credo"
           ]

    # Together with the "cc_lab:" already on the line, these are full ids.
    assert Enum.map(
             complete(dir, "mix composer.step.run cc_lab:ash/"),
             &("cc_lab:" <> &1)
           ) ==
             ["cc_lab:ash/postgres"]
  end

  test "completes the last item of a comma-separated list", %{tmp_dir: dir} do
    # Bash replaces the word after the last ":", so "ash/" becomes "ash/postgres".
    assert complete(dir, "mix composer.step.run core:setup/credo,cc_lab:ash/") == [
             "ash/postgres"
           ]
  end

  test "recipe tasks complete recipe ids, group by group", %{tmp_dir: dir} do
    assert complete(dir, "mix composer.recipe.run lo") ==
             ["local:ash/auth", "local:ash/base", "local:lv/base"]

    # Together with "local:" on the line: the recipes in the ash group.
    assert complete(dir, "mix composer.recipe.show local:ash/") == ["ash/auth", "ash/base"]
    assert complete(dir, "mix composer.recipe.edit local:lv/") == ["lv/base"]
    assert complete(dir, "mix composer.recipe.help local:lv/") == ["lv/base"]
  end

  test "recipe.list completes cookbooks and groups, in every position", %{tmp_dir: dir} do
    assert complete(dir, "mix composer.recipe.list lo") ==
             ["local:ash/", "local:lv/", "local"]

    assert complete(dir, "mix composer.recipe.list local c") ==
             ["cc_lab:lv/", "cc_lab", "core"]

    assert complete(dir, "mix composer.recipe.list local:a") == ["ash/"]
  end

  test "offers nothing when the index is older than mix.lock", %{tmp_dir: dir} do
    File.touch!(Path.join(dir, "mix.lock"))
    File.touch!(Path.join(dir, "_build/composer/index"), System.os_time(:second) - 60)
    assert Enum.reject(complete(dir, "mix composer.step.run co"), &(&1 =~ "stale")) == []
  end

  test "everything else is delegated to mix_completions", %{tmp_dir: dir} do
    assert complete(dir, "mix comp") == ["delegated"]
    assert complete(dir, "mix composer.step.run --dr") == ["delegated"]
  end
end
