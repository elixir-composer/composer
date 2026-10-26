defmodule Composer.CompletionFishTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  unless System.find_executable("fish"), do: @moduletag(skip: "fish is not installed")

  @script Path.expand("lib/composer/cb_std/steps/completions/_composer/composer.fish")

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

  # Calls `__composer_complete mode` once per {mode, token}, in one fish
  # process, with `commandline -ct` stubbed, and returns
  # {[[{candidate, description}]], stderr}. A stem has no description.
  defp session(dir, calls) do
    stderr = Path.join(dir, ".stderr")

    tabs =
      Enum.map_join(calls, "\n", fn {mode, token} ->
        """
        set -g __token #{shell_quote(token)}
        __composer_complete #{mode}
        echo '<end>'
        """
      end)

    script = """
    source #{@script}
    function commandline; echo $__token; end
    #{tabs}
    """

    # A hint comes from a command substitution, whose stderr a redirect on
    # the call doesn't catch, so capture fish's own stderr.
    {output, 0} =
      System.cmd("bash", ["-c", ~s(fish --no-config -c "$1" 2>"$2"), "fish", script, stderr],
        cd: dir
      )

    results =
      output
      |> String.split("<end>\n")
      |> Enum.drop(-1)
      |> Enum.map(fn out ->
        for line <- String.split(out, "\n", trim: true) do
          [candidate, description] = String.split(line, "\t")
          {candidate, description}
        end
      end)

    {results, if(File.exists?(stderr), do: File.read!(stderr), else: "")}
  end

  defp shell_quote(word), do: "'" <> String.replace(word, "'", ~S(\')) <> "'"

  test "a step segment, and the last item of a comma-separated list", %{tmp_dir: dir} do
    assert {[first, second], ""} =
             session(dir, [{"step", "cb_std:"}, {"step", "cb_std:tidy,cb_std:setup:"}])

    assert first == [{"cb_std:setup:", ""}, {"cb_std:tidy", "Tidies"}]
    assert second == [{"cb_std:tidy,cb_std:setup:credo", "Adds Credo"}]
  end

  test "a recipe segment, and a root address", %{tmp_dir: dir} do
    assert {[first, second], ""} = session(dir, [{"recipe", "mine/"}, {"recipe", "/l"}])
    assert first == [{"mine/ash/", ""}, {"mine/lv/", ""}]
    assert second == [{"/lv/", ""}]
  end

  test "a stale index offers nothing, with one hint per session", %{tmp_dir: dir} do
    File.touch!(Path.join(dir, "mix.lock"))
    File.touch!(Path.join(dir, "_build/composer/index"), System.os_time(:second) - 60)

    assert {[[], []], stderr} = session(dir, [{"step", "cb"}, {"recipe", "m"}])

    assert String.split(stderr, "\n", trim: true) == [
             "(composer: the completion index is stale; run mix composer.index)"
           ]
  end
end
