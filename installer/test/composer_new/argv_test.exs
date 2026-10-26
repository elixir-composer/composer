defmodule ComposerNew.ArgvTest do
  use ExUnit.Case, async: true

  alias ComposerNew.Argv

  defp parse!(argv) do
    assert {:ok, parsed} = Argv.parse(argv)
    parsed
  end

  test "APP alone, with defaults" do
    parsed = parse!(~w(my_app))
    assert parsed.app == "my_app"

    assert Enum.sort(parsed.opts) ==
             Enum.sort(
               with: nil,
               with_args: nil,
               install: [],
               composer: nil,
               cookbook: [],
               recipe: nil,
               recipe_args: nil,
               extra_dep: [],
               igniter_local: nil,
               reset: false,
               dry_run: false
             )
  end

  test "--cookbook, --recipe and --recipe-args" do
    parsed =
      parse!([
        "my_app",
        "--cookbook",
        "cb_lab@github:o/cb_lab",
        "--recipe",
        "cb_lab/phx/saas",
        "--cookbook=cb_more",
        "--recipe-args=--oban-pro --gigalixir",
        "--dry-run"
      ])

    assert parsed.opts[:cookbook] == ~w(cb_lab@github:o/cb_lab cb_more)
    assert parsed.opts[:recipe] == "cb_lab/phx/saas"
    assert parsed.opts[:recipe_args] == "--oban-pro --gigalixir"
    assert parsed.opts[:dry_run]
  end

  test "--with-args and --recipe-args take a separate value starting with -" do
    assert parse!(["a", "--with-args=--no-ecto --binary-id"]).opts[:with_args] ==
             "--no-ecto --binary-id"

    parsed = parse!(["a", "--with-args", "--a --b", "--recipe", "x/y/z", "--recipe-args", "--c"])
    assert parsed.opts[:with_args] == "--a --b"
    assert parsed.opts[:recipe_args] == "--c"
  end

  test "= inside a value is kept" do
    assert parse!(["a", "--with-args=--x=1"]).opts[:with_args] == "--x=1"

    assert parse!(["a", "--extra-dep=foo@git:https://h/x?a=b"]).opts[:extra_dep] ==
             ["foo@git:https://h/x?a=b"]
  end

  test "--install, --cookbook and --extra-dep repeat; --install splits on ," do
    parsed =
      parse!(~w(a --install a,b --install c --extra-dep x --extra-dep=y@path:../y --cookbook p))

    assert parsed.opts[:install] == ~w(a b c)
    assert parsed.opts[:extra_dep] == ~w(x y@path:../y)
    assert parsed.opts[:cookbook] == ~w(p)
  end

  test "help?/1 skips the values of --with-args and --recipe-args" do
    assert Argv.help?(~w(a --help))
    assert Argv.help?(~w(-h))
    refute Argv.help?(~w(a --with-args --help))
    refute Argv.help?(~w(a --recipe x/y/z --recipe-args -h))
    refute Argv.help?(~w(a --recipe-args=--help))
  end

  test "errors" do
    assert {:error, "Give the app name first" <> _} = Argv.parse([])

    assert {:error, "The first argument must be the app name, got: --reset" <> _} =
             Argv.parse(~w(--reset a))

    assert {:error, "Unexpected argument \"cb_lab/lv/base\"" <> rest} =
             Argv.parse(~w(a cb_lab/lv/base))

    assert rest =~ "name the recipe with --recipe cb_lab/lv/base"

    assert {:error, "Unknown option --oban-pro. Recipe flags go in --recipe-args" <> _} =
             Argv.parse(~w(a --recipe x/y/z --oban-pro))

    assert {:error, "Unknown option --reset=true" <> _} = Argv.parse(~w(a --reset=true))
    assert {:error, "Unknown option --no-recipe" <> _} = Argv.parse(~w(a --no-recipe))
    assert {:error, "Unknown option --" <> _} = Argv.parse(~w(a -- --x))
    assert {:error, "--with needs a value"} = Argv.parse(~w(a --with))
    assert {:error, "--composer needs a value"} = Argv.parse(~w(a --composer --reset))
    assert {:error, "--with-args needs a value"} = Argv.parse(~w(a --with-args))

    assert {:error, "--recipe may be given only once"} =
             Argv.parse(~w(a --recipe x/y/z --recipe=x/y/w))

    assert {:error, "--recipe-args may be given only once"} =
             Argv.parse(~w(a --recipe x/y/z --recipe-args=-a --recipe-args=-b))

    assert {:error, "--recipe-args needs --recipe" <> _} = Argv.parse(~w(a --recipe-args=--x))
  end
end
