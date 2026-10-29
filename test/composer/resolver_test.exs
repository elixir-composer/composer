defmodule Composer.ResolverTest do
  use ExUnit.Case, async: true

  alias Composer.{Recipe, Resolver}
  import Composer.Test.Cookbooks

  @moduletag :tmp_dir

  # Cookbooks: cb_std, fake_book, other_book, and the cookbook mine built from
  # `recipes`, a map of "chapter/name" => steps source. Every if: flag in the
  # steps is declared.
  defp cookbooks(dir, recipes \\ %{}) do
    recipes
    |> Enum.group_by(fn {id, _} -> Path.dirname(id) end)
    |> Enum.each(fn {chapter, entries} ->
      body =
        Enum.map_join(entries, ",\n", fn {id, source} ->
          {steps, _} = Code.eval_string(source)
          flags = for flag <- Recipe.if_flags(steps), do: {flag, "x"}

          "  #{Path.basename(id)}: [shortdoc: #{inspect(id)}, flags: #{inspect(flags)}, steps: #{source}]"
        end)

      path = Path.join([dir, "recipes", chapter <> ".exs"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "[\n" <> body <> "\n]\n")
    end)

    discover(dir, [:fake_book, :other_book])
  end

  defp resolve(cookbooks, ref, opts \\ []), do: Resolver.resolve_recipe(cookbooks, ref, opts)

  defp refs({:ok, %{steps: entries}}), do: Enum.map(entries, & &1.label)
  defp refs(entries) when is_list(entries), do: Enum.map(entries, & &1.label)

  @nested %{cookbook: "nested_book", chapter: "ash/ui/tailwind", cli?: false}
  @cli %{cookbook: nil, chapter: nil, cli?: true}

  describe "scopes" do
    setup %{tmp_dir: dir} do
      %{books: discover(dir, [:nested_book, :fake_book, :other_book])}
    end

    test "nested chapters resolve, through relative includes", %{books: books} do
      assert {:ok, result} = resolve(books, "nested_book/ash/ui/tailwind/full")

      assert refs({:ok, result}) == [
               "nested_book:cluster:dns",
               "nested_book:ui:button",
               "nested_book:echo"
             ]

      assert Enum.map(result.recipes, & &1.ref) == [
               "nested_book/ash/ui/tailwind/full",
               "nested_book/ash/ui/tailwind/base",
               "nested_book/ash/ui/tailwind/forms/inputs",
               "nested_book/ash/ui/buttons",
               "nested_book/ash/core"
             ]
    end

    test "every row of the relative table", %{books: books} do
      for {written, id} <- [
            {"./base", "nested_book/ash/ui/tailwind/base"},
            {"./forms/inputs", "nested_book/ash/ui/tailwind/forms/inputs"},
            {"../buttons", "nested_book/ash/ui/buttons"},
            {"../../core", "nested_book/ash/core"}
          ] do
        assert Resolver.find_recipe(books, written, @nested) == {:ok, id}
      end

      assert {:error, {:above_root, "../../../core", nil, "ash/ui/tailwind"} = reason} =
               Resolver.find_recipe(books, "../../../core", @nested)

      assert Composer.Error.message(reason) =~ "climbs above recipes/"
      assert Composer.Error.message(reason) =~ "no chapter for core"

      assert {:error, {:above_root, _, _, _}} =
               Resolver.find_recipe(books, "../../../../ash/core", @nested)

      assert Resolver.find_recipe(books, "../../../ash/core", @nested) ==
               {:ok, "nested_book/ash/core"}
    end

    test "relative() is the relative table", %{books: _books} do
      assert Resolver.relative("ash", 0, ["x"]) == {:ok, "ash/x"}
      assert Resolver.relative("ash/ui", 1, ["core"]) == {:ok, "ash/core"}
      assert Resolver.relative("ash", 1, ["core"]) == {:error, :above_root}
      assert Resolver.relative("ash", 2, ["a", "b"]) == {:error, :above_root}
    end

    test "ash/ui.exs and ash/ui/ are different chapters", %{books: books} do
      assert {:ok, "nested_book/ash/ui/buttons"} =
               Resolver.find_recipe(books, "/ash/ui/buttons", @nested)

      assert {:error, {:missing_recipe, _, _, _}} =
               Resolver.find_recipe(books, "/ash/ui/tailwind", @nested)
    end

    test "root addresses are the context cookbook's", %{books: books} do
      assert Resolver.find_recipe(books, "/ash/core", @nested) == {:ok, "nested_book/ash/core"}

      assert {:ok, {:step, %{ref: "nested_book:ui:button"}}} =
               Resolver.find_step(books, ":ui:button", @nested)

      assert {:error, {:not_a_cookbook, "/ash/core", nil} = reason} =
               Resolver.find_recipe(books, "/ash/core", @cli)

      assert Composer.Error.message(reason) =~ "this project is not a cookbook"
    end

    test "a relative address on the command line has no chapter", %{books: books} do
      context = %{@cli | cookbook: "nested_book"}

      assert {:error, {:no_chapter, "./base", nil}} =
               Resolver.find_recipe(books, "./base", context)
    end

    test "a recipe address needs a chapter; the step twin is suggested", %{books: books} do
      assert {:error,
              {:kind_mismatch, :recipe, "nested_book/echo", nil, "nested_book:echo"} =
                reason} = Resolver.find_recipe(books, "nested_book/echo", @cli)

      assert Composer.Error.message(reason) ==
               "no recipe nested_book/echo; did you mean the step nested_book:echo?"

      assert {:error, {:short_recipe, "/nothing", nil}} =
               Resolver.find_recipe(books, "/nothing", @nested)
    end

    test "a missing step whose recipe twin exists says so", %{books: books} do
      assert {:error, {:kind_mismatch, :step, "nested_book:ash:core", nil, twin} = reason} =
               Resolver.find_step(books, "nested_book:ash:core", @cli)

      assert twin == "nested_book/ash/core"

      assert Composer.Error.message(reason) ==
               "no step nested_book:ash:core; did you mean the recipe nested_book/ash/core?"
    end

    test "a step address where a recipe is expected, and the reverse", %{books: books} do
      assert {:error, {:kind_mismatch, :recipe, "other_book:setup:credo", nil, nil} = reason} =
               Resolver.find_recipe(books, "other_book:setup:credo", @cli)

      assert Composer.Error.message(reason) =~ "is a step address"

      assert {:error, {:kind_mismatch, :step, "cb_std/debug/echo", nil, nil}} =
               Resolver.find_step(books, "cb_std/debug/echo", @cli)

      assert {:error, {:kind_mismatch, :step, "nested_book/ui/button", nil, twin}} =
               Resolver.find_step(books, "nested_book/ui/button", @cli)

      assert twin == "nested_book:ui:button"
    end

    test "adding a cookbook changes nothing", %{tmp_dir: dir, books: books} do
      few = discover(dir, [:nested_book])
      assert {:ok, before} = resolve(few, "nested_book/ash/ui/tailwind/full")
      assert {:ok, later} = resolve(books, "nested_book/ash/ui/tailwind/full")
      strip = fn result -> Enum.map(result.steps, &Map.take(&1, [:ref, :step, :origin])) end
      assert strip.(before) == strip.(later)
    end
  end

  describe "search on the command line" do
    setup %{tmp_dir: dir} do
      %{books: discover(dir, [:nested_book, :fake_book, :other_book])}
    end

    test "a unique last segment resolves", %{books: books} do
      assert {:ok, [%{ref: "other_book:setup:sort_deps"}]} =
               Resolver.resolve_steps(books, ["sort_deps"], context: @cli)

      assert Resolver.find_recipe(books, "inputs", @cli) ==
               {:ok, "nested_book/ash/ui/tailwind/forms/inputs"}
    end

    test "several matches are ambiguous, listed canonically", %{books: books} do
      assert {:error, {:ambiguous, :address, "libcluster", nil, ids}} =
               Resolver.find_step(books, "libcluster", @cli)

      assert ids == ["other_book:cluster:gigalixir:libcluster", "other_book:cluster:libcluster"]
    end

    test "a recipe and a step tie", %{books: books} do
      assert {:error, {:ambiguous, :address, "echo", nil, ids}} =
               Resolver.find_recipe(books, "echo", @cli)

      assert ids == ["cb_std/debug/echo", "cb_std:echo", "nested_book:echo"]
    end

    test "a match of the other kind is a kind mismatch", %{books: books} do
      assert {:error, {:kind_mismatch, :recipe, "button", nil, "nested_book:ui:button"}} =
               Resolver.find_recipe(books, "button", @cli)
    end

    test "there is no Hex fallback", %{books: books} do
      assert {:error, {:no_match, :step, "some_unrelated_package", [], false} = reason} =
               Resolver.resolve_steps(books, ["some_unrelated_package"], context: @cli)

      assert Composer.Error.message(reason) =~ ~s(write "hex:some_unrelated_package")

      assert {:error, {:no_match, :recipe, "fake_book", _, true} = reason} =
               Resolver.find_recipe(books, "fake_book", @cli)

      assert Composer.Error.message(reason) =~ "fake_book is a cookbook"
    end
  end

  describe "step addresses" do
    test "qualified addresses resolve exactly", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/p" => ~s(["other_book:setup:credo", "fake_book:ash:postgres", "hex:oban"])
        })

      assert {:ok, %{steps: [credo, postgres, oban]}} = resolve(books, "mine/g/p")
      assert credo.step == {:module, Composer.OtherBook.Steps.Setup.Credo}
      assert postgres.step == {:module, Composer.FakeBook.Steps.Ash.Postgres}
      assert oban.step == {:install, :oban, []}
      assert credo.origin == "mine/g/p"
    end

    test "a root address is a step of the recipe's own cookbook", %{tmp_dir: dir} do
      books = cookbooks(dir)

      # other_book/main/shared says ":hello", which other_book and fake_book both have.
      assert {:ok, %{steps: [from_base, own]}} = resolve(books, "other_book/main/shared")
      assert from_base.ref == "fake_book:hello"
      assert own.ref == "other_book:hello"
    end

    test "a bare word in source is an error naming what it could mean", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["oban"]), "g/q" => ~s(["credo"])})

      assert {:error, {:bare_word, "oban", "mine/g/p", ["hex:oban"], []} = reason} =
               resolve(books, "mine/g/p")

      assert Composer.Error.message(reason) =~ ~s("oban" is not an address; write "hex:oban")

      assert {:error, {:bare_word, "credo", "mine/g/q", candidates, []} = reason} =
               resolve(books, "mine/g/q")

      assert candidates == ["fake_book:setup:credo", "other_book:setup:credo"]
      assert Composer.Error.message(reason) =~ ~s(did you mean "fake_book:setup:credo" or)
    end

    test "a bare word naming one of the cookbook's own steps has one rewrite", %{tmp_dir: dir} do
      books = discover(dir, [:nested_book])

      context = %{cookbook: "nested_book", chapter: "ash", cli?: false}

      # cb_std has an echo step and recipe too, but echo meant this one.
      assert {:error, {:bare_word, "echo", nil, [":echo"], []}} =
               Resolver.find_step(books, "echo", context)

      assert {:error, {:bare_word, "button", nil, ["nested_book:ui:button"], []}} =
               Resolver.find_step(books, "button", context)
    end

    test "a bare typo suggests the close step, not a Hex package", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["gitignroe"])})

      assert {:error, {:bare_word, "gitignroe", "mine/g/p", [], ["other_book:setup:gitignore"]}} =
               resolve(books, "mine/g/p")
    end

    test "a missing step has suggestions", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["fake_book:ash:postgress"])})

      assert {:error,
              {:missing_step, "fake_book:ash:postgress", "mine/g/p", ["fake_book:ash:postgres"]}} =
               resolve(books, "mine/g/p")
    end

    test "a step that moved into a group is suggested first", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["other_book:gigalixir:libcluster"])})

      assert {:error, {:missing_step, _, _, ["other_book:cluster:gigalixir:libcluster" | _]}} =
               resolve(books, "mine/g/p")
    end

    test "a step whose name became a group is suggested first", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["other_book:setup_gitignore"])})

      assert {:error, {:missing_step, _, _, ["other_book:setup:gitignore" | _]}} =
               resolve(books, "mine/g/p")
    end

    test "an unknown cookbook suggests adding the package", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["cc_lab:ash"])})

      assert {:error, {:unknown_cookbook, "cc_lab", _, _, _} = reason} =
               resolve(books, "mine/g/p")

      assert Composer.Error.message(reason) =~ "{:cc_lab, \"~> x.y\", only: :dev}"
    end

    test "an unknown cookbook that is a dependency suggests recompiling it" do
      # igniter is one of composer's deps, and defines no cookbook.
      message = Composer.Error.message({:unknown_cookbook, "igniter", "igniter/x/y", nil, []})
      assert message =~ "igniter is a dependency, but defines no cookbook"
      assert message =~ "mix deps.compile igniter --force"
      refute message =~ "~> x.y"
    end

    test "relative steps are reserved", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s([".:dns"])})

      assert {:error, {:invalid_ref, ".:dns", "relative step references are not supported yet"}} =
               resolve(books, "mine/g/p")
    end

    test "resolve_steps/3 resolves command-line addresses with argv", %{tmp_dir: dir} do
      books = cookbooks(dir)

      assert {:ok, [args, credo]} =
               Resolver.resolve_steps(books, ["fake_book:args", ":setup:credo"],
                 context: %{@cli | cookbook: "other_book"},
                 argv: ["--bar"]
               )

      assert args.step == {:module, Composer.FakeBook.Steps.Args, ["--bar"]}
      assert credo.ref == "other_book:setup:credo"
    end
  end

  describe "old syntax" do
    test "is an error naming the new spelling", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/mixed" => ~s(["other_book:setup/credo"]),
          "g/path" => ~s(["ash/postgres"]),
          "g/both" => ~s(["setup/credo"])
        })

      assert {:error,
              {:old_syntax, "mine/g/mixed", "other_book:setup/credo", ["other_book:setup:credo"]}} =
               resolve(books, "mine/g/mixed")

      assert {:error,
              {:old_syntax, "mine/g/path", "ash/postgres", ["fake_book:ash:postgres"]} =
                reason} = resolve(books, "mine/g/path")

      assert Composer.Error.message(reason) =~ "mix composer.cookbook.lint --fix"

      assert {:error,
              {:old_syntax, _, "setup/credo", ["fake_book:setup:credo", "other_book:setup:credo"]}} =
               resolve(books, "mine/g/both")
    end

    test "{:use, ...} is an error showing the rewritten entry", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/a" => ~s([{:use, "b", if: :x}]),
          "g/b" => ~s([{:use, "fake_book:main/base"}]),
          "g/c" => ~s([{:use, "main/base"}])
        })

      assert {:error,
              {:use_entry, "mine/g/a", {:use, "b", [if: :x]}, [~s({"./b", if: :x})]} =
                reason} = resolve(books, "mine/g/a")

      assert Composer.Error.message(reason) =~ ~s(Write {"./b", if: :x} instead)

      assert {:error, {:use_entry, _, _, [~s("fake_book/main/base")]}} =
               resolve(books, "mine/g/b")

      assert {:error, {:use_entry, _, _, [~s("fake_book/main/base"), ~s("other_book/main/base")]}} =
               resolve(books, "mine/g/c")
    end
  end

  test "argv: passes options to a recipe's step and shows in its label", %{tmp_dir: dir} do
    books =
      cookbooks(dir, %{
        "g/p" =>
          ~s([{"fake_book:args", argv: ["--bar"]}, {"fake_book:args", argv: ["--bar"], if: :x}])
      })

    assert {:ok, %{steps: [args, gated], duplicates: []}} = resolve(books, "mine/g/p")
    assert args.step == {:module, Composer.FakeBook.Steps.Args, ["--bar"]}
    assert args.label == "fake_book:args --bar"
    assert gated.if == :x
  end

  describe "hex: options" do
    test "argv, dep options and sources are carried into a canonical install step", %{
      tmp_dir: dir
    } do
      books =
        cookbooks(dir, %{
          "g/p" => ~s([
            {"hex:ash_authentication", argv: ["--auth-strategy", "password"]},
            {"hex:mix_test_watch", runtime: false, only: [:test, :dev, :test]},
            {"hex:x", ref: "main", github: "a/b"},
            {"hex:my_lib", path: "../my_lib", only: :dev},
            "hex:ash@3.5",
            "hex:y@github:a/y@v1"
          ])
        })

      assert {:ok, %{steps: entries}} = resolve(books, "mine/g/p")

      assert Enum.map(entries, & &1.step) == [
               {:install, :ash_authentication, [argv: ["--auth-strategy", "password"]]},
               {:install, :mix_test_watch, [dep: [only: [:dev, :test], runtime: false]]},
               {:install, :x, [source: [github: "a/b", ref: "main"]]},
               {:install, :my_lib, [source: [path: "../my_lib"], dep: [only: [:dev]]]},
               {:install, :ash, [source: [version: "~> 3.0"]]},
               {:install, :y, [source: [github: "a/y", ref: "v1"]]}
             ]

      assert refs(entries) == [
               "hex:ash_authentication --auth-strategy password",
               "hex:mix_test_watch",
               "hex:x (github a/b, ref main)",
               "hex:my_lib (path ../my_lib)",
               "hex:ash (version ~> 3.0)",
               "hex:y (github a/y, ref v1)"
             ]

      # The ref stays source-free, so requires: ["hex:pkg"] matches by name.
      assert Enum.map(entries, & &1.ref) ==
               ~w(hex:ash_authentication hex:mix_test_watch hex:x hex:my_lib hex:ash hex:y)
    end

    test "identical installs dedupe, however they are written", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/p" => ~s(["./a", "./b", {"hex:t", only: [:dev]}]),
          "g/a" => ~s([{"hex:t", only: :dev}]),
          "g/b" => ~s([{"hex:t", only: [:dev, :dev]}])
        })

      assert {:ok, %{steps: [tidewave], duplicates: [_, _]}} = resolve(books, "mine/g/p")
      assert tidewave.step == {:install, :t, [dep: [only: [:dev]]]}
      assert tidewave.origin == "mine/g/a"
    end

    test "different options for one package conflict, naming every origin", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/argv" => ~s(["./plain", {"hex:oban", argv: ["--x"]}]),
          "g/plain" => ~s(["hex:oban"]),
          "g/source" => ~s([{"hex:oban", path: "../a"}, {"hex:oban", path: "../b"}]),
          "g/flags" => ~s([{"hex:oban", only: :dev, if: :a}, {"hex:oban", if: :b}])
        })

      assert {:error, {:conflicting_install, "oban", installs} = reason} =
               resolve(books, "mine/g/argv")

      assert installs == [{"mine/g/plain", "hex:oban"}, {"mine/g/argv", "hex:oban --x"}]
      message = Composer.Error.message(reason)
      assert message =~ "hex:oban  (mine/g/plain)"
      assert message =~ "hex:oban --x  (mine/g/argv)"

      assert {:error, {:conflicting_install, "oban", [{_, "hex:oban (path ../a)"}, _]}} =
               resolve(books, "mine/g/source")

      # Strict: both flags may be on at once, and :all checks every path.
      assert {:error, {:conflicting_install, "oban", _}} = resolve(books, "mine/g/flags")

      assert {:error, {:conflicting_install, "oban", [{nil, _}, {nil, _}]} = reason} =
               Resolver.resolve_steps(books, ["hex:oban", "hex:oban@1.0"])

      assert Composer.Error.message(reason) =~ "(the command line)"
    end

    test "package options on a step are an error", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s([{"fake_book:ash:postgres", argv: [], if: :x}])})
      assert {:ok, _} = resolve(books, "mine/g/p")

      {[], [error]} =
        Composer.Recipe.Chapter.check(
          [
            p: [shortdoc: "x", flags: [x: "x"], steps: [{"fake_book:ash:postgres", path: "../x"}]]
          ],
          "g.exs",
          "mine"
        )

      assert {:hex_only_option, "mine/g/p", _, :path} = error
    end

    test "an @ source and a keyword source conflict", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s([{"hex:ash@3.5", version: "~> 3.5"}])})
      assert {:error, {:source_conflict, "mine/g/p", _}} = resolve(books, "mine/g/p")
    end

    test "resolve_steps/3 carries the @ source, and argv to the installer", %{tmp_dir: dir} do
      books = cookbooks(dir)

      assert {:ok, [a]} = Resolver.resolve_steps(books, ["hex:my_lib@path:../my-lib"])
      assert a.step == {:install, :my_lib, [source: [path: "../my-lib"]]}

      assert {:ok, [b]} = Resolver.resolve_steps(books, ["hex:my_lib"], argv: ["--a", "b"])
      assert b.step == {:install, :my_lib, [argv: ["--a", "b"]]}
      assert b.label == "hex:my_lib --a b"
    end

    test "requires: [\"hex:pkg\"] is satisfied by a sourced install", %{tmp_dir: dir} do
      books = cookbooks(dir)
      {:ok, [install]} = Resolver.resolve_steps(books, ["hex:my_lib@path:../my_lib"])

      needs = %{
        ref: "x:needs",
        label: "x:needs",
        step: {:module, Foo},
        meta: %Composer.Step.Meta{cookbook: "x", requires: ["hex:my_lib"]}
      }

      refute Enum.any?(Resolver.warnings([install, needs]), &(elem(&1, 0) == :requires_order))
      assert [{:requires_order, _, "hex:my_lib"}] = Resolver.warnings([needs])
    end
  end

  describe "recipes" do
    test "includes expand in place, nested, across cookbooks", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/a" => ~s(["./b", "other_book:setup:sort_deps"]),
          "g/b" => ~s(["other_book:setup:credo", "fake_book/main/base"])
        })

      assert {:ok, result} = resolve(books, "mine/g/a")

      assert refs({:ok, result}) == [
               "other_book:setup:credo",
               "fake_book:hello",
               "other_book:setup:sort_deps"
             ]

      assert Enum.map(result.recipes, & &1.ref) == [
               "mine/g/a",
               "mine/g/b",
               "fake_book/main/base"
             ]

      assert Enum.map(result.steps, & &1.origin) == [
               "mine/g/b",
               "fake_book/main/base",
               "mine/g/a"
             ]
    end

    test "a root address on the command line finds this project's recipe", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/mine" => ~s(["other_book:setup:credo"])})

      assert {:ok, %{root: "mine/g/mine"}} =
               resolve(books, "/g/mine", context: %{@cli | cookbook: "mine"})
    end

    test "an include takes only if:", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/a" => ~s([{"./b", argv: ["x"]}]), "g/b" => ~s([])})

      assert {:error, {:include_options, "mine/g/a", "./b", [:argv]} = reason} =
               resolve(books, "mine/g/a")

      assert Composer.Error.message(reason) =~ "an include takes only if:"
    end

    test "a diamond expands once and is not a cycle", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/top" => ~s(["./left", "./right"]),
          "g/left" => ~s(["./shared", "other_book:setup:credo"]),
          "g/right" => ~s(["./shared", "other_book:setup:quokka"]),
          "g/shared" => ~s(["other_book:setup:gitignore"])
        })

      assert refs(resolve(books, "mine/g/top")) == [
               "other_book:setup:gitignore",
               "other_book:setup:credo",
               "other_book:setup:quokka"
             ]
    end

    test "duplicates are dropped on the resolved id, first wins", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/p" =>
            ~s(["other_book:setup:gitignore", "other_book:setup:gitignore", {"other_book:setup:gitignore", if: :x}])
        })

      assert {:ok, result} = resolve(books, "mine/g/p")
      assert refs({:ok, result}) == ["other_book:setup:gitignore", "other_book:setup:gitignore"]
      assert Enum.map(result.steps, & &1.if) == [nil, :x]
      assert [%{label: "other_book:setup:gitignore", if: nil}] = result.duplicates
    end

    test "{:task, ...} and {:queue, ...} are leaves", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s([{:task, "a.b", ["x"]}, {:queue, "c.d", [], if: :q}])})

      assert {:ok, %{steps: [task, queue]}} = resolve(books, "mine/g/p")
      assert task.step == {:task, "a.b", ["x"]}
      assert queue.step == {:queue, "c.d", []}
      assert queue.if == :q
    end
  end

  describe "chapters" do
    test "relative and root includes across chapters", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "ash/base" => ~s(["other_book:setup:credo"]),
          "ash/ecto" => ~s(["./base", "other_book:setup:gitignore"]),
          "lv/base" => ~s(["other_book:setup:quokka"]),
          "lv/app" => ~s(["./base", "/ash/ecto"])
        })

      assert {:ok, result} = resolve(books, "mine/lv/app")

      assert refs({:ok, result}) == [
               "other_book:setup:quokka",
               "other_book:setup:credo",
               "other_book:setup:gitignore"
             ]

      assert Enum.map(result.recipes, & &1.ref) ==
               ["mine/lv/app", "mine/lv/base", "mine/ash/ecto", "mine/ash/base"]
    end

    test "a relative include missing from the chapter fails", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "ash/base" => ~s(["other_book:setup:credo"]),
          "ash/ecto" => ~s(["./bsae"])
        })

      assert {:error, {:missing_recipe, "./bsae", "mine/ash/ecto", ["mine/ash/base" | _]}} =
               resolve(books, "mine/ash/ecto")
    end

    test "a same-chapter cycle reports its path", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/a" => ~s(["./b"]), "g/b" => ~s(["./a"])})

      assert {:error, {:cycle, ["mine/g/a", "mine/g/b", "mine/g/a"]}} =
               resolve(books, "mine/g/a")
    end

    test "declared_flags/1 is the union over every recipe reached", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "recipes"))

      File.write!(Path.join(dir, "recipes/g.exs"), """
      [
        app: [shortdoc: "App", flags: [own: "Own"], steps: [{"./deploy", if: :own}]],
        deploy: [shortdoc: "Deploy", flags: [gigalixir: "Gigalixir"], steps: [{"other_book:cluster:gigalixir", if: :gigalixir}]]
      ]
      """)

      books = discover(dir, [:other_book])
      {:ok, result} = resolve(books, "mine/g/app")
      assert Resolver.declared_flags(result) == [own: "Own", gigalixir: "Gigalixir"]
    end

    test "a chapter file that fails to load names the file", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "recipes"))
      File.write!(Path.join(dir, "recipes/g.exs"), "[a: [shortdoc: \"A\", steps: [], extra: 1]]")
      books = discover(dir, [])

      assert {:error, {:unknown_recipe_key, "mine/g/a", :extra}} = resolve(books, "mine/g/a")
    end
  end

  describe "flags" do
    setup %{tmp_dir: dir} do
      %{
        books:
          cookbooks(dir, %{
            "g/app" =>
              ~s(["./base", {"./deploy", if: :deploy}, {"other_book:setup:credo", if: :credo}]),
            "g/base" => ~s(["other_book:setup:gitignore"]),
            "g/deploy" => ~s(["other_book:cluster:gigalixir", {"./cluster", if: :cluster}]),
            "g/cluster" => ~s(["other_book:cluster:libcluster"]),
            "g/late" => ~s([{"./deploy", if: :deploy}, "./deploy"])
          })
      }
    end

    test "a gated include follows its flag", %{books: books} do
      assert refs(resolve(books, "mine/g/app", flags: [deploy: true])) ==
               [
                 "other_book:setup:gitignore",
                 "other_book:cluster:gigalixir",
                 "other_book:setup:credo"
               ]

      assert refs(resolve(books, "mine/g/app", flags: [])) == [
               "other_book:setup:gitignore",
               "other_book:setup:credo"
             ]
    end

    test ":all follows every gate and records it; nested gates accumulate", %{books: books} do
      assert {:ok, result} = resolve(books, "mine/g/app")
      assert Resolver.flags(result) == [:deploy, :cluster, :credo]

      assert List.last(Enum.filter(result.steps, &(&1.ref == "other_book:cluster:libcluster"))).gates ==
               [:deploy, :cluster]
    end

    test "a gated-off include still expands through a later ungated include", %{books: books} do
      assert refs(resolve(books, "mine/g/late", flags: [])) == ["other_book:cluster:gigalixir"]
    end

    test "active/2 drops entries whose own if: is off", %{books: books} do
      {:ok, result} = resolve(books, "mine/g/app", flags: [])
      assert refs(Resolver.active(result.steps, [])) == ["other_book:setup:gitignore"]

      assert refs(Resolver.active(result.steps, credo: true)) == [
               "other_book:setup:gitignore",
               "other_book:setup:credo"
             ]
    end
  end

  describe "errors" do
    test "cycles report the full path, across cookbooks", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/a" => ~s(["./b"]),
          "g/b" => ~s(["./c"]),
          "g/c" => ~s(["mine/g/a"]),
          "g/self" => ~s(["./self"])
        })

      assert {:error, {:cycle, ["mine/g/a", "mine/g/b", "mine/g/c", "mine/g/a"]}} =
               resolve(books, "mine/g/a")

      assert {:error, {:cycle, ["mine/g/self", "mine/g/self"]}} = resolve(books, "mine/g/self")

      assert Composer.Error.message({:cycle, ["mine/g/a", "mine/g/b", "mine/g/a"]}) =~
               "mine/g/a -> mine/g/b"
    end

    test "a cycle hidden behind a gate is caught by flags: :all", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/a" => ~s([{"./b", if: :x}]), "g/b" => ~s(["./a"])})
      assert {:ok, _} = resolve(books, "mine/g/a", flags: [])
      assert {:error, {:cycle, _}} = resolve(books, "mine/g/a")
    end

    test "a missing include names the recipe", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/a" => ~s([{"./nope", if: :x}])})
      assert {:ok, _} = resolve(books, "mine/g/a", flags: [])
      assert {:error, {:missing_recipe, "./nope", "mine/g/a", _}} = resolve(books, "mine/g/a")
    end

    test "old forms are rejected", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/a" => "[{:add, :credo}]"})

      assert {:error, {:legacy_form, "mine/g/a", {:add, :credo}, ~s("credo")}} =
               resolve(books, "mine/g/a")
    end

    test "local is no cookbook: its steps and recipes are unknown", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/step" => ~s(["local:x:y"]), "g/use" => ~s(["local/x/y"])})

      assert {:error, {:unknown_cookbook, "local", "local:x:y", "mine/g/step", _}} =
               resolve(books, "mine/g/step")

      assert {:error, {:unknown_cookbook, "local", "local/x/y", "mine/g/use", _}} =
               resolve(books, "mine/g/use")
    end

    test "validate_all/2 checks every recipe, optionally of some cookbooks", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/broken" => ~s(["./missing"])})

      assert {:error, {:missing_recipe, "./missing", "mine/g/broken", _}} =
               Resolver.validate_all(books)

      assert :ok = Resolver.validate_all(books, only: ["fake_book", "other_book"])
    end
  end

  describe "warnings/1" do
    test "phase order, provides overlaps, conflicts and requires order", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/p" => ~s(["fake_book:ash:postgres", "fake_book:sqlite", "fake_book:hello"])
        })

      {:ok, %{steps: entries}} = resolve(books, "mine/g/p")

      warnings = Resolver.warnings(entries)
      messages = Enum.map(warnings, &Composer.Error.warning/1)

      assert {:phase_order, %{ref: "fake_book:sqlite"}, %{ref: "fake_book:ash:postgres"}} =
               Enum.find(warnings, &(elem(&1, 0) == :phase_order))

      assert Enum.any?(
               messages,
               &(&1 =~ "fake_book:ash:postgres, fake_book:sqlite all provide :datalayer")
             )

      assert Enum.any?(
               messages,
               &(&1 =~
                   "fake_book:sqlite conflicts with :datalayer, which fake_book:ash:postgres provides")
             )

      assert Enum.any?(
               messages,
               &(&1 =~
                   "fake_book:ash:postgres requires fake_book:hello, which is not listed before it")
             )
    end

    test "a requirement listed earlier is satisfied", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["fake_book:hello", "fake_book:ash:postgres"])})
      {:ok, %{steps: entries}} = resolve(books, "mine/g/p")
      refute Enum.any?(Resolver.warnings(entries), &(elem(&1, 0) == :requires_order))
    end

    test "a root requirement is the step's own cookbook; there is no suffix match" do
      hello = %{ref: "fake_book:hello", label: "fake_book:hello", step: nil, meta: nil}
      other = %{ref: "other_book:hello", label: "other_book:hello", step: nil, meta: nil}

      needs = fn requires ->
        %{
          ref: "fake_book:x",
          label: "fake_book:x",
          step: nil,
          meta: %Composer.Step.Meta{cookbook: "fake_book", requires: requires}
        }
      end

      assert Resolver.warnings([hello, needs.([":hello"])]) == []
      assert [{:requires_order, _, ":hello"}] = Resolver.warnings([other, needs.([":hello"])])

      assert Resolver.requirement_id(":a:b", "cb") == "cb:a:b"
      assert Resolver.requirement_id("x:a", "cb") == "x:a"
      assert Resolver.requirement_id("hex:p@1.0", "cb") == "hex:p"
      assert Resolver.requirement_id("./x", "cb") == nil
    end
  end

  describe "cookbook aliases" do
    # A chapter file `g.exs` with the given recipes source.
    defp aliased(dir, source) do
      path = Path.join([dir, "recipes", "g.exs"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
      discover(dir, [:fake_book, :other_book])
    end

    test "an aliased step or include resolves like the qualified form", %{tmp_dir: dir} do
      books =
        aliased(dir, """
        [
          aliased: [
            shortdoc: "x",
            aliases: [fb: "fake_book", ob: "other_book"],
            steps: ["fb:ash:postgres", "ob/main/shared"]
          ],
          qualified: [
            shortdoc: "x",
            steps: ["fake_book:ash:postgres", "other_book/main/shared"]
          ]
        ]
        """)

      assert {:ok, aliased} = resolve(books, "mine/g/aliased")
      assert {:ok, qualified} = resolve(books, "mine/g/qualified")

      strip = fn result -> Enum.map(result.steps, &Map.take(&1, [:ref, :label, :step])) end
      assert strip.(aliased) == strip.(qualified)
      assert [%{alias: "fb"}, %{alias: nil} | _] = aliased.steps
      assert "other_book/main/shared" in Enum.map(aliased.recipes, & &1.ref)
    end

    test "an alias does not apply inside an included recipe", %{tmp_dir: dir} do
      books =
        aliased(dir, """
        [
          a: [shortdoc: "x", aliases: [fb: "fake_book"], steps: ["fb:hello", "./b"]],
          b: [shortdoc: "x", steps: ["fb:hello"]]
        ]
        """)

      assert {:error, {:unknown_cookbook, "fb", "fb:hello", "mine/g/b", _} = reason} =
               resolve(books, "mine/g/a")

      assert Composer.Error.message(reason) =~ "declare it in mine/g/b's aliases:"
    end

    test "an alias does not apply on the command line", %{tmp_dir: dir} do
      books = aliased(dir, ~s([a: [shortdoc: "x", aliases: [fb: "fake_book"], steps: []]]))

      assert {:error, {:unknown_cookbook, "fb", _, nil, _}} =
               Resolver.resolve_steps(books, ["fb:hello"])
    end

    test "an alias may not shadow an installed cookbook", %{tmp_dir: dir} do
      books =
        aliased(dir, ~s([a: [shortdoc: "x", aliases: [other_book: "fake_book"], steps: []]]))

      assert {:error, {:alias_shadows_cookbook, "mine/g/a", :other_book}} =
               resolve(books, "mine/g/a")
    end

    test "errors name both the alias and its target", %{tmp_dir: dir} do
      books =
        aliased(dir, """
        [
          missing: [shortdoc: "x", aliases: [lab: "cc_lab"], steps: ["lab:auth:passkeys"]],
          no_step: [shortdoc: "x", aliases: [fb: "fake_book"], steps: ["fb:nope:nothing"]]
        ]
        """)

      assert {:error, reason} = resolve(books, "mine/g/missing")
      assert {:unknown_alias_target, "lab:auth:passkeys", "lab", "cc_lab", _, _} = reason

      assert Composer.Error.message(reason) =~
               "lab:auth:passkeys (lab = cc_lab): cookbook cc_lab not found"

      assert {:error, {:via_alias, _, "fb", "fake_book", {:missing_step, _, _, _}} = reason} =
               resolve(books, "mine/g/no_step")

      assert Composer.Error.message(reason) =~ ~s("fb:nope:nothing" uses the alias fb = fake_book)
    end
  end
end
