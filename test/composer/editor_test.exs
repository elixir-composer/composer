defmodule Composer.EditorTest do
  use ExUnit.Case, async: true

  alias Composer.Editor

  @moduletag :tmp_dir

  describe "command/3" do
    test "substitutes __FILE__ and __LINE__" do
      env = %{"COMPOSER_EDITOR" => "ghostty -e 'nvim +__LINE__ __FILE__'"}

      assert Editor.command("/r/phx.exs", 12, env) ==
               {:ok, "ghostty -e 'nvim +12 /r/phx.exs'"}
    end

    test "appends the quoted file when there is no __FILE__" do
      assert Editor.command("/my r/it's.exs", 3, %{"EDITOR" => "nvim"}) ==
               {:ok, ~S(nvim '/my r/it'\''s.exs')}
    end

    test "prefers COMPOSER_EDITOR, then VISUAL, then EDITOR, skipping blanks" do
      env = %{"COMPOSER_EDITOR" => " ", "VISUAL" => "vis", "EDITOR" => "ed"}
      assert Editor.command("f", 1, env) == {:ok, "vis 'f'"}
      assert Editor.command("f", 1, Map.put(env, "COMPOSER_EDITOR", "ce")) == {:ok, "ce 'f'"}
      assert Editor.command("f", 1, Map.delete(env, "VISUAL")) == {:ok, "ed 'f'"}
    end

    test "fails without an editor" do
      assert Editor.command("f", 1, %{}) == {:error, :no_editor}
    end
  end

  describe "run/1" do
    test "runs the command and reports its exit status", %{tmp_dir: dir} do
      out = Path.join(dir, "out")
      assert Editor.run("echo hi > '#{out}'") == :ok
      assert File.read!(out) == "hi\n"
      assert Editor.run("exit 3") == {:error, {:exit, 3}}
    end
  end
end
