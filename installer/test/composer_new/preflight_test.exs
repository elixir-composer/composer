defmodule ComposerNew.PreflightTest do
  use ExUnit.Case, async: true

  alias ComposerNew.{Plan, Preflight}

  @env %{cwd: "/work", home: "/home/me", version: "0.3.0"}

  @all_good [
    exists?: &__MODULE__.never/1,
    task?: &__MODULE__.always/1,
    igniter_new_version: &__MODULE__.current/0,
    executable?: &__MODULE__.always/1
  ]

  def never(_), do: false
  def always(_), do: true
  def current, do: "0.5.35"

  defp check(argv, checks \\ []) do
    {:ok, plan} = Plan.build(argv, @env)
    Preflight.check(plan, Keyword.merge(@all_good, checks))
  end

  test "passes when everything is there" do
    assert check(~w(my_app --with phx.new)) == {:ok, []}
  end

  test "APP must not exist, unless --reset" do
    exists = [exists?: &(&1 == "/work/my_app")]
    assert {:error, ["/work/my_app already exists." <> _]} = check(~w(my_app), exists)
    assert {:ok, []} = check(~w(my_app --reset), exists)
  end

  test "igniter_new must be installed, at 0.5.32 or later" do
    no_igniter = [task?: &(&1 != "igniter.new")]

    assert {:error, [message]} = check(~w(my_app), no_igniter)
    assert message =~ "mix archive.install hex igniter_new"

    assert {:error, [message]} = check(~w(my_app), igniter_new_version: fn -> "0.5.31" end)
    assert message =~ "igniter_new >= 0.5.32 is required (0.5.31 is installed)"
    assert message =~ "mix archive.install hex igniter_new --force"

    assert {:ok, []} = check(~w(my_app), igniter_new_version: fn -> "0.5.32" end)
  end

  test "an unknown igniter_new version warns" do
    assert {:ok, [warning]} = check(~w(my_app), igniter_new_version: fn -> nil end)
    assert warning =~ "Can't tell which igniter_new"
  end

  test "the --with task must exist" do
    no_with = [task?: &(&1 == "igniter.new")]

    assert {:error, [message]} = check(~w(my_app --with phx.new), no_with)
    assert message == "--with phx.new needs the phx_new archive: mix archive.install hex phx_new"

    assert {:error, [message]} = check(~w(my_app --with ash.new), no_with)
    assert message =~ "probably comes from the ash_new archive"

    # The default, new, comes with Elixir.
    assert {:ok, []} = check(~w(my_app --with new), no_with)
    assert {:ok, []} = check(~w(my_app), no_with)
  end

  test "reports every problem at once" do
    assert {:error, problems} =
             check(~w(my_app --with phx.new),
               exists?: &always/1,
               task?: &never/1,
               executable?: &never/1
             )

    assert length(problems) == 4
    assert List.last(problems) =~ "git is required"
  end
end
