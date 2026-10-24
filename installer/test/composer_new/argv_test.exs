defmodule ComposerNew.ArgvTest do
  use ExUnit.Case, async: true

  alias ComposerNew.Argv

  defp parse!(argv) do
    assert {:ok, parsed} = Argv.parse(argv)
    parsed
  end

  test "APP and REF, with defaults" do
    parsed = parse!(~w(my_app cb_lab:lv/base))
    assert parsed.app == "my_app"
    assert parsed.ref == "cb_lab:lv/base"
    assert parsed.recipe_flags == []

    assert Enum.sort(parsed.opts) ==
             Enum.sort(
               with: nil,
               with_args: nil,
               install: [],
               composer: nil,
               extra_dep: [],
               igniter_local: nil,
               reset: false,
               dry_run: false,
               no_recipe: false
             )
  end

  test "no REF" do
    parsed = parse!(~w(my_app --reset))
    assert parsed.ref == nil
    assert parsed.opts[:reset]
  end

  test "own options versus recipe flags, interleaved, in order" do
    parsed =
      parse!(
        ~w(my_app --oban-pro cb_lab:phx/saas --with phx.new --gigalixir -x --dry-run --no-recipe)
      )

    assert parsed.ref == "cb_lab:phx/saas"
    assert parsed.opts[:with] == "phx.new"
    assert parsed.opts[:dry_run]
    assert parsed.opts[:no_recipe]
    assert parsed.recipe_flags == ~w(--oban-pro --gigalixir -x)
  end

  test "--with-args with =, and with a separate value starting with -" do
    assert parse!(["a", "--with-args=--no-ecto --binary-id"]).opts[:with_args] ==
             "--no-ecto --binary-id"

    parsed = parse!(["a", "--with-args", "--a --b", "--c"])
    assert parsed.opts[:with_args] == "--a --b"
    assert parsed.recipe_flags == ["--c"]
  end

  test "= inside a value is kept" do
    assert parse!(["a", "--with-args=--x=1"]).opts[:with_args] == "--x=1"

    assert parse!(["a", "--extra-dep=foo@git:https://h/x?a=b"]).opts[:extra_dep] ==
             ["foo@git:https://h/x?a=b"]
  end

  test "--install and --extra-dep repeat; --install splits on ," do
    parsed = parse!(~w(a --install a,b --install c --extra-dep x --extra-dep=y@path:../y))
    assert parsed.opts[:install] == ~w(a b c)
    assert parsed.opts[:extra_dep] == ~w(x y@path:../y)
  end

  test "everything after -- is a recipe flag" do
    parsed = parse!(~w(a cb_std:debug/echo --gigalixir -- --reset --with x extra))
    assert parsed.recipe_flags == ~w(--gigalixir --reset --with x extra)
    refute parsed.opts[:reset]
    assert parsed.opts[:with] == nil
  end

  test "a boolean with = is not an own option" do
    assert parse!(~w(a --reset=true)).recipe_flags == ["--reset=true"]
  end

  test "errors" do
    assert {:error, "Give the app name first" <> _} = Argv.parse([])

    assert {:error, "The first argument must be the app name, got: --reset" <> _} =
             Argv.parse(~w(--reset a))

    assert {:error, "Unexpected argument \"extra\"" <> _} = Argv.parse(~w(a b:c/d extra))
    assert {:error, "--with needs a value"} = Argv.parse(~w(a --with))
    assert {:error, "--composer needs a value"} = Argv.parse(~w(a --composer --reset))
    assert {:error, "--with-args needs a value"} = Argv.parse(~w(a --with-args))
  end
end
