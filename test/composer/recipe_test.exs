defmodule Composer.RecipeTest do
  use ExUnit.Case, async: true

  alias Composer.Recipe

  test "accepts every entry form" do
    entries = [
      "credo",
      {"core:oban_pro", if: :oban_pro},
      {"fake_book:args", argv: ["--bar"]},
      {"fake_book:args", argv: [], if: :args},
      {:use, "base"},
      {:use, "deploy", if: :gigalixir},
      {:task, "ash.codegen"},
      {:task, "ash.codegen", ["init"]},
      {:queue, "ecto.setup", [], if: :db}
    ]

    assert {:ok, ^entries} = Recipe.validate(entries, "local:g/p")
    assert Recipe.if_flags(entries) == [:oban_pro, :args, :gigalixir, :db]
  end

  test "a non-list is a shape error" do
    assert {:error, {:recipe_shape, "x", %{}}} = Recipe.validate(%{}, "x")
  end

  test "old step forms are rejected with the new syntax" do
    cases = [
      {{:add, :credo}, ~s("credo")},
      {{:remove, :topbar}, ~s("remove_topbar")},
      {{:install, :ash}, ~s("hex:ash")},
      {{:add, :oban, if: :oban}, ~s({"oban", if: :oban})},
      {{:gen, :hello, from: StartReg}, ~s("start_reg:hello")},
      {{:use, :base}, ~s({:use, "base"})}
    ]

    for {entry, suggestion} <- cases do
      assert {:error, {:legacy_form, "local:x", ^entry, ^suggestion}} =
               Recipe.validate([entry], "local:x")
    end

    assert {:error, {:legacy_form, _, {:composer, Foo}, _}} =
             Recipe.validate([{:composer, Foo}], "x")

    assert {:error, {:legacy_form, _, MyApp.Step, _}} = Recipe.validate([MyApp.Step], "x")

    message = Composer.Error.message({:legacy_form, "local:x", {:add, :credo}, ~s("credo")})
    assert message =~ "Write it as \"credo\" instead"
  end

  test "rejects malformed entries" do
    for entry <- [
          {"credo", []},
          {"credo", argv: [], argv: []},
          {"credo", :x},
          {:use, "x", if: [:a]},
          {:task, :x},
          1
        ] do
      assert {:error, {:invalid_entry, "x", ^entry}} = Recipe.validate([entry], "x")
    end
  end

  describe "hex: entry options" do
    test "are accepted on hex: and unqualified references" do
      entries = [
        "hex:ash",
        "hex:ash@3.5",
        {"hex:ash", version: "~> 3.5"},
        {"hex:ash_authentication", argv: ["--auth-strategy", "password"]},
        {"hex:mix_test_watch", only: [:dev, :test], runtime: false},
        {"hex:live_debugger", github: "software-mansion/live-debugger", only: :dev},
        {"hex:my_lib", path: "../my_lib", if: :lib},
        {"hex:x", github: "a/b", ref: "main"},
        {"hex:x", git: "https://h/x.git", branch: "b", sparse: "sub", submodules: true},
        {"hex:x@github:a/b", tag: "v1"},
        {"hex:oban.oban_pro", version: "~> 1.0"},
        {"tidewave", only: :dev}
      ]

      assert {:ok, ^entries} = Recipe.validate(entries, "r")
    end

    test "a bad value names the key and the value" do
      for {key, value} <- [
            if: true,
            argv: "--all",
            argv: [:all],
            only: "dev",
            only: [],
            only: [:dev, "test"],
            runtime: "false",
            version: "banana",
            path: "",
            github: :ash,
            submodules: 1
          ] do
        entry = {"hex:x", [{key, value}]}

        assert {:error, {:bad_entry_option, "r", ^entry, ^key, ^value} = reason} =
                 Recipe.validate([entry], "r")

        assert Composer.Error.message(reason) =~ "invalid #{key}: #{inspect(value)}"
      end
    end

    test "an unknown key is reported" do
      entry = {"hex:x", foo: 1}
      assert {:error, {:unknown_entry_option, "r", ^entry, :foo}} = Recipe.validate([entry], "r")
    end

    test "package options on a qualified step reference are an error" do
      entry = {"core:setup/credo", only: :dev}

      assert {:error, {:hex_only_option, "r", ^entry, :only} = reason} =
               Recipe.validate([entry], "r")

      assert Composer.Error.message(reason) =~ "for hex: entries only"
      assert {:ok, _} = Recipe.validate([{"core:setup/credo", argv: ["--x"]}], "r")
    end

    test "sources combine only one way" do
      cases = [
        {{"hex:x", path: "../x", github: "a/b"}, {:multiple_sources, [:path, :github]}},
        {{"hex:x", ref: "main"}, {:git_option_without_git, :ref}},
        {{"hex:x", path: "../x", submodules: true}, {:git_option_without_git, :submodules}},
        {{"hex:x", github: "a/b", ref: "main", branch: "b"},
         {:multiple_git_refs, [:ref, :branch]}},
        {{"hex:x@github:a/b@main", tag: "v1"}, {:multiple_git_refs, [:tag, :ref]}},
        {{"hex:x@3.5", path: "../x"}, :source_conflict},
        {{"hex:org.pkg", git: "https://h/x.git"}, {:repo_source, :git}}
      ]

      for {entry, expected} <- cases do
        assert {:error, reason} = Recipe.validate([entry], "r")

        case expected do
          :source_conflict -> assert reason == {:source_conflict, "r", entry}
          {kind, detail} -> assert reason == {kind, "r", entry, detail}
        end

        assert is_binary(Composer.Error.message(reason))
        refute Composer.Error.message(reason) =~ "composer error:"
      end
    end

    test "an invalid reference string is reported as such" do
      assert {:error, {:invalid_ref, "ash@3.5", _}} = Recipe.validate([{"ash@3.5", if: :x}], "r")
    end
  end

  test "summary/1 is the shortdoc's first line" do
    assert Recipe.summary(%Recipe{shortdoc: "One\ntwo"}) == "One"
    assert Recipe.summary(nil) == ""
  end
end
