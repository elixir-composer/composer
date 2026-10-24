defmodule Composer.Recipe.GroupTest do
  use ExUnit.Case, async: true

  alias Composer.{Error, Recipe}
  alias Composer.Recipe.Group

  @fixtures "test/support/fixtures/groups"

  defp fixture(name), do: Path.join(@fixtures, name <> ".exs")
  defp load(name), do: Group.load(fixture(name), "mine")

  test "loads every recipe of a group, with its metadata" do
    assert {:ok, [base, app]} = load("clean")

    assert %Recipe{
             id: "clean/base",
             ref: "mine:clean/base",
             cookbook: "mine",
             group: "clean",
             name: "base",
             shortdoc: "The base",
             doc: nil,
             flags: [],
             steps: ["core:setup/gitignore"]
           } = base

    assert base.path == fixture("clean")
    assert app.doc == "Builds on clean/base.\n"
    assert app.flags == [credo: "Add Credo"]
  end

  test "ids/1 reads names from the syntax tree, matching load/2" do
    assert Group.ids(fixture("clean")) == {:ok, ["app", "base"]}
    {:ok, recipes} = load("clean")
    assert Enum.sort(Enum.map(recipes, & &1.name)) == ["app", "base"]

    # Never evaluated.
    assert Group.ids(fixture("raises")) ==
             {:error, {:group_shape, fixture("raises"), :not_literal}}

    # Bindings before a literal list are fine.
    assert Group.ids(fixture("bindings")) == {:ok, ["base"]}
    assert {:ok, [%{steps: ["core:setup/gitignore"]}]} = load("bindings")
  end

  test "a non-literal top level cannot be listed" do
    path = fixture("not_literal")
    assert Group.ids(path) == {:error, {:group_shape, path, :not_literal}}
    assert Error.message({:group_shape, path, :not_literal}) =~ "literal keyword list"
  end

  test "an empty group has no recipes" do
    assert load("empty") == {:ok, []}
    assert Group.ids(fixture("empty")) == {:ok, []}
  end

  test "an old single-recipe file points at the group format" do
    path = fixture("old_format")
    assert {:error, {:group_shape, ^path, ["core:setup/credo", _]} = reason} = load("old_format")
    message = Error.message(reason)
    assert message =~ "keyword list of recipes"
    assert message =~ "shortdoc:"
    assert message =~ "single-recipe file"
  end

  test "shape errors name the file and recipe" do
    path = fixture("not_keyword")
    assert {:error, {:group_shape, ^path, %{}}} = load("not_keyword")

    assert {:error, {:recipe_missing_key, "mine:missing_shortdoc/base", :shortdoc}} =
             load("missing_shortdoc")

    assert {:error, {:unknown_recipe_key, "mine:unknown_key/base", :help} = reason} =
             load("unknown_key")

    assert Error.message(reason) =~ "mine:unknown_key/base has an unknown key :help"

    assert {:error, {:bad_recipe_value, "mine:bad_value/base", :shortdoc, ""}} =
             load("bad_value")

    assert {:error, {:undeclared_flag, "mine:undeclared_flag/base", :credo} = reason} =
             load("undeclared_flag")

    assert Error.message(reason) =~ ~s(flags: [credo: "What --credo does"])
  end

  test "a flag named like a mix composer.new option is reserved" do
    assert {:error, {:reserved_flag, "mine:reserved_flag/base", :with} = reason} =
             load("reserved_flag")

    assert Error.message(reason) =~ "--with is reserved by mix composer.new"

    {term, _} = Code.eval_file(fixture("reserved_flag"))
    {[], errors} = Group.check(term, fixture("reserved_flag"), "mine")

    assert Enum.sort(errors) == [
             {:reserved_flag, "mine:reserved_flag/base", :extra_dep},
             {:reserved_flag, "mine:reserved_flag/base", :with}
           ]
  end

  test "reserved flags cover recipe.run, Igniter and mix composer.new" do
    reserved = Recipe.reserved_flags()

    for flag <- ~w(no_commit yes dry_run only with with_args install composer extra_dep
                   igniter_local reset no_recipe recipe)a,
        do: assert(flag in reserved, "#{flag} is not reserved")

    assert reserved == Enum.uniq(reserved)
    assert Recipe.archive_flag?(:with_args)
    refute Recipe.archive_flag?(:dry_run)
    refute Recipe.archive_flag?(:no_commit)
  end

  test "check/3 reports every problem" do
    {term, _} = Code.eval_file(fixture("bad_value"))
    {[], errors} = Group.check(term, fixture("bad_value"), "mine")

    assert {:bad_recipe_value, "mine:bad_value/base", :shortdoc, ""} in errors
    assert {:bad_recipe_value, "mine:bad_value/base", :flags, [credo: 1]} in errors
  end

  test "duplicate recipe names are an error" do
    path = fixture("duplicate")
    assert {:error, {:duplicate_recipe, ^path, "base"} = reason} = load("duplicate")
    assert Error.message(reason) =~ "defines the recipe base more than once"
    assert {:ok, names} = Group.names(path)
    assert Group.duplicates(names) == ["base"]
  end

  test "a raising file and a syntax error are reported" do
    # The line of the failure in the file is kept, for lint.
    assert {:error, {:recipe_eval, "mine:raises/", _, %RuntimeError{}, 1}} = load("raises")

    path = "test/support/fixtures/syntax_error.exs"
    assert {:error, {:group_parse, ^path, _, 1}} = Group.ids(path)
    assert {:error, {:recipe_eval, _, ^path, _, 1}} = Group.load(path, "mine")
  end

  test "group names are lowercase segments" do
    assert {:error, {:invalid_group_name, _}} = load("BadName")
    assert Group.valid_name?("lv_base")
    refute Group.valid_name?("lv-base")
    refute Group.valid_name?("My Group")
  end

  describe "aliases" do
    test "a shared alias binding loads into each recipe, and names/1 still reads it" do
      assert {:ok, [base, app]} = load("aliases")
      assert base.aliases == [fb: "fake_book"]
      assert app.aliases == [fb: "fake_book"]
      assert {:ok, %{aliases: []}} = Recipe.load(fixture("clean"), "mine", "base")

      assert Group.names(fixture("aliases")) == {:ok, ["base", "app"]}
      assert Group.ids(fixture("aliases")) == {:ok, ["app", "base"]}
    end

    test "invalid aliases are per-recipe errors; siblings still load" do
      path = fixture("bad_aliases")
      assert {:ok, {[good], errors}} = Group.load_all(path, "mine")
      assert good.name == "good"

      assert {:reserved_alias, "mine:bad_aliases/reserved", :core} in errors
      assert {:invalid_alias, "mine:bad_aliases/malformed", :Lab} in errors
      assert {:duplicate_alias, "mine:bad_aliases/duplicate", :fb} in errors
      assert {:alias_atom_target, "mine:bad_aliases/atom", :fb, :fake_book} in errors

      for {name, target} <- [h: "hex", c: "core", l: "local"] do
        assert {:invalid_alias_target, "mine:bad_aliases/virtual", name, target} in errors
      end

      assert {:error, {:alias_atom_target, _, _, _} = reason} =
               Group.pick({[good], errors}, path, "mine", "atom")

      assert Error.message(reason) =~ ~s(aliases: [fb: "fake_book"])
      assert Error.message({:reserved_alias, "r", :core}) =~ "reserved"
    end
  end

  test "Recipe.load/3 picks one recipe by name" do
    assert {:ok, %{ref: "mine:clean/app"}} = Recipe.load(fixture("clean"), "mine", "app")

    assert {:error, {:missing_recipe, "mine:clean/nope", nil, []}} =
             Recipe.load(fixture("clean"), "mine", "nope")
  end
end
