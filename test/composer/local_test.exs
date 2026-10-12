defmodule Composer.LocalTest do
  # Sets COMPOSER_CONFIG and XDG_CONFIG_HOME.
  use ExUnit.Case, async: false

  alias Composer.{Local, Cookbook}

  @moduletag :tmp_dir

  setup do
    saved = for var <- ["COMPOSER_CONFIG", "XDG_CONFIG_HOME"], do: {var, System.get_env(var)}

    on_exit(fn ->
      for {var, value} <- saved,
          do: if(value, do: System.put_env(var, value), else: System.delete_env(var))
    end)

    System.delete_env("COMPOSER_CONFIG")
    System.delete_env("XDG_CONFIG_HOME")
    :ok
  end

  # Writes a group file holding the given recipe names.
  defp group!(dir, group, names) do
    path = Path.join([dir, "recipes", group <> ".exs"])
    File.mkdir_p!(Path.dirname(path))
    entries = Enum.map_join(names, ", ", &"#{&1}: [shortdoc: \"A recipe\", steps: []]")
    File.write!(path, "[#{entries}]\n")
  end

  test "applies the precedence: -c, COMPOSER_CONFIG, XDG_CONFIG_HOME, ~/.config", %{tmp_dir: dir} do
    assert Local.dir() == {Path.expand("~/.config/composer"), :default}

    System.put_env("XDG_CONFIG_HOME", Path.join(dir, "xdg"))
    assert Local.dir() == {Path.join([dir, "xdg", "composer"]), :default}

    System.put_env("COMPOSER_CONFIG", Path.join(dir, "env"))
    assert Local.dir() == {Path.join(dir, "env"), :explicit}

    assert Local.dir(Path.join(dir, "flag")) == {Path.join(dir, "flag"), :explicit}

    System.put_env("COMPOSER_CONFIG", "")
    assert Local.dir() == {Path.join([dir, "xdg", "composer"]), :default}
  end

  test "loads recipes from the default directory", %{tmp_dir: dir} do
    System.put_env("XDG_CONFIG_HOME", dir)
    group!(Path.join(dir, "composer"), "phx", ["standard_app", "cleanup"])
    group!(Path.join(dir, "composer"), "ash", ["base"])

    assert {:ok, %Cookbook{name: "local", kind: :local} = local} = Local.cookbook()
    assert Cookbook.recipes(local) == ["ash/base", "phx/cleanup", "phx/standard_app"]
    assert Cookbook.steps(local) == []
  end

  test "-c and COMPOSER_CONFIG point at another directory", %{tmp_dir: dir} do
    group!(Path.join(dir, "env"), "g", ["from_env"])
    group!(Path.join(dir, "flag"), "g", ["from_flag"])
    System.put_env("COMPOSER_CONFIG", Path.join(dir, "env"))

    assert {:ok, env} = Local.cookbook()
    assert Cookbook.recipes(env) == ["g/from_env"]

    assert {:ok, flag} = Local.cookbook(Path.join(dir, "flag"))
    assert Cookbook.recipes(flag) == ["g/from_flag"]
  end

  test "a missing default directory is an empty cookbook", %{tmp_dir: dir} do
    System.put_env("XDG_CONFIG_HOME", Path.join(dir, "nothing"))
    assert {:ok, local} = Local.cookbook()
    assert Cookbook.recipes(local) == []
  end

  test "an explicit missing directory, or a file, is an error", %{tmp_dir: dir} do
    missing = Path.join(dir, "missing")
    assert {:error, {:config_dir_missing, ^missing}} = Local.cookbook(missing)

    file = Path.join(dir, "recipes.exs")
    File.write!(file, "[]")
    assert {:error, {:config_dir_not_dir, ^file}} = Local.cookbook(file)
    assert Composer.Error.message({:config_dir_not_dir, file}) =~ "single recipes.exs file"
  end

  test "steps/ and templates/ are rejected: local holds recipes only", %{tmp_dir: dir} do
    for entry <- ["steps", "templates"] do
      config = Path.join(dir, entry)
      File.mkdir_p!(Path.join(config, entry))
      assert {:error, {:local_recipes_only, ^config, ^entry} = reason} = Local.cookbook(config)
      assert Composer.Error.message(reason) =~ "Local holds recipes only"
    end
  end

  test "other entries do not stop loading; dot entries are ignored", %{tmp_dir: dir} do
    group!(dir, "g", ["a"])
    File.write!(Path.join(dir, "settings.exs"), "[]")
    File.mkdir_p!(Path.join(dir, ".cache"))

    assert {:ok, local} = Local.cookbook(dir)
    assert Cookbook.recipes(local) == ["g/a"]
    assert Local.entries(dir) == ["settings.exs"]
  end

  test "a group's recipes are addressed group/name; subdirectories are not groups", %{
    tmp_dir: dir
  } do
    group!(dir, "ash", ["base", "auth"])
    group!(Path.join(dir, "recipes"), "nested", ["x"])
    File.write!(Path.join([dir, "recipes", "Bad-Name.exs"]), "[x: [shortdoc: \"x\", steps: []]]")

    {:ok, local} = Local.cookbook(dir)
    assert Cookbook.recipes(local) == ["ash/auth", "ash/base"]
    assert Cookbook.recipe_path(local, "ash/base") == Path.join([dir, "recipes", "ash.exs"])
    assert Cookbook.recipe_path(local, "ash/nope") == nil
    assert Cookbook.recipe_path(local, "nope/base") == nil
    assert Cookbook.recipe_path(local, "base") == nil
    assert Cookbook.group_path(local, "ash") == Path.join([dir, "recipes", "ash.exs"])
    assert Enum.map(Cookbook.groups(local), &elem(&1, 0)) == ["ash"]
  end
end
