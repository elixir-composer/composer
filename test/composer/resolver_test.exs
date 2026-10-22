defmodule Composer.ResolverTest do
  use ExUnit.Case, async: true

  alias Composer.{Discovery, Recipe, Resolver}

  @moduletag :tmp_dir

  # Cookbooks: core, fake_book, other_book, and a local cookbook built from
  # `recipes`, a map of "group/name" => steps source. Every if: flag in the
  # steps is declared.
  defp cookbooks(dir, recipes \\ %{}) do
    recipes
    |> Enum.group_by(fn {id, _} -> Path.dirname(id) end)
    |> Enum.each(fn {group, entries} ->
      body =
        Enum.map_join(entries, ",\n", fn {id, source} ->
          {steps, _} = Code.eval_string(source)
          flags = for flag <- Recipe.if_flags(steps), do: {flag, "x"}

          "  #{Path.basename(id)}: [shortdoc: #{inspect(id)}, flags: #{inspect(flags)}, steps: #{source}]"
        end)

      path = Path.join([dir, "recipes", group <> ".exs"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "[\n" <> body <> "\n]\n")
    end)

    {:ok, cookbooks} = Discovery.cookbooks(apps: [:fake_book, :other_book], config: dir)
    cookbooks
  end

  defp resolve(cookbooks, ref, opts \\ []), do: Resolver.resolve_recipe(cookbooks, ref, opts)

  defp refs({:ok, %{steps: entries}}), do: Enum.map(entries, & &1.label)
  defp refs(entries) when is_list(entries), do: Enum.map(entries, & &1.label)

  describe "step references" do
    test "qualified references resolve exactly", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{"g/p" => ~s(["core:setup/credo", "fake_book:ash/postgres", "hex:oban"])})

      assert {:ok, %{steps: [credo, postgres, oban]}} = resolve(books, "local:g/p")
      assert credo.step == {:module, Composer.Core.Steps.Setup.Credo}
      assert postgres.step == {:module, Composer.FakeBook.Steps.Ash.Postgres}
      assert oban.step == {:install, :oban, []}
      assert credo.origin == "local:g/p"
    end

    test "an unqualified reference prefers the referring recipe's own cookbook", %{tmp_dir: dir} do
      books = cookbooks(dir)

      # other_book:main/shared says "hello", which other_book and fake_book both have.
      assert {:ok, %{steps: [from_base, own]}} = resolve(books, "other_book:main/shared")
      assert from_base.ref == "fake_book:hello"
      assert own.ref == "other_book:hello"
    end

    test "otherwise an unqualified reference is searched everywhere", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["setup/gitignore", "ash/postgres"])})

      assert refs(resolve(books, "local:g/p")) == [
               "core:setup/gitignore",
               "fake_book:ash/postgres"
             ]
    end

    test "more than one match is ambiguous, listing the candidates", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["setup/credo"])})

      assert {:error,
              {:ambiguous, :step, "setup/credo", "local:g/p",
               ["core:setup/credo", "fake_book:setup/credo"]}} =
               resolve(books, "local:g/p")
    end

    test "no match and no / is a Hex package", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["oban_web", "some_unrelated_package"])})
      assert {:ok, %{steps: [a, b]}} = resolve(books, "local:g/p")
      assert a.step == {:install, :oban_web, []}
      assert b.ref == "hex:some_unrelated_package"
    end

    test "a near miss of a step id is a typo, not a Hex lookup", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["gitignroe"])})

      assert {:error, {:typo, "gitignroe", "local:g/p", ["core:setup/gitignore"]}} =
               resolve(books, "local:g/p")
    end

    test "no match with a / is missing, with suggestions", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["ash/postgress", "fake_book:nope"])})

      assert {:error, {:missing_step, "ash/postgress", "local:g/p", ["fake_book:ash/postgres"]}} =
               resolve(books, "local:g/p")
    end

    test "a step that moved into a group is suggested first", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["core:gigalixir/libcluster"])})

      assert {:error, {:missing_step, _, _, ["core:cluster/gigalixir/libcluster" | _]}} =
               resolve(books, "local:g/p")
    end

    test "a step whose name became a group is suggested first", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["core:setup_gitignore"])})

      assert {:error, {:missing_step, _, _, ["core:setup/gitignore" | _]}} =
               resolve(books, "local:g/p")
    end

    test "an unknown cookbook suggests adding the package", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["cc_lab:ash"])})

      assert {:error, {:unknown_cookbook, "cc_lab", _, _, _} = reason} =
               resolve(books, "local:g/p")

      assert Composer.Error.message(reason) =~ "{:cc_lab, \"~> x.y\", only: :dev}"
    end

    test "resolve_steps/3 resolves command-line refs with own-cookbook context and argv", %{
      tmp_dir: dir
    } do
      books = cookbooks(dir)

      assert {:ok, [args, credo]} =
               Resolver.resolve_steps(books, ["fake_book:args", "setup/credo"],
                 context: "core",
                 argv: ["--bar"]
               )

      assert args.step == {:module, Composer.FakeBook.Steps.Args, ["--bar"]}
      assert credo.ref == "core:setup/credo"
    end
  end

  test "argv: passes options to a recipe's step and shows in its label", %{tmp_dir: dir} do
    books =
      cookbooks(dir, %{
        "g/p" =>
          ~s([{"fake_book:args", argv: ["--bar"]}, {"fake_book:args", argv: ["--bar"], if: :x}])
      })

    assert {:ok, %{steps: [args, gated], duplicates: []}} = resolve(books, "local:g/p")
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

      assert {:ok, %{steps: entries}} = resolve(books, "local:g/p")

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
          "g/p" => ~s([{:use, "a"}, {:use, "b"}, {"hex:t", only: [:dev]}]),
          "g/a" => ~s([{"hex:t", only: :dev}]),
          "g/b" => ~s([{"t", only: :dev}])
        })

      assert {:ok, %{steps: [tidewave], duplicates: [_, _]}} = resolve(books, "local:g/p")
      assert tidewave.step == {:install, :t, [dep: [only: [:dev]]]}
      assert tidewave.origin == "local:g/a"
    end

    test "an unqualified Hex fallback keeps its options", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s([{"some_pkg", path: "../p", argv: ["--x"]}])})
      assert {:ok, %{steps: [entry]}} = resolve(books, "local:g/p")
      assert entry.step == {:install, :some_pkg, [argv: ["--x"], source: [path: "../p"]]}
    end

    test "different options for one package conflict, naming every origin", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/argv" => ~s([{:use, "plain"}, {"hex:oban", argv: ["--x"]}]),
          "g/plain" => ~s(["hex:oban"]),
          "g/source" => ~s([{"hex:oban", path: "../a"}, {"hex:oban", path: "../b"}]),
          "g/flags" => ~s([{"hex:oban", only: :dev, if: :a}, {"hex:oban", if: :b}])
        })

      assert {:error, {:conflicting_install, "oban", installs} = reason} =
               resolve(books, "local:g/argv")

      assert installs == [{"local:g/plain", "hex:oban"}, {"local:g/argv", "hex:oban --x"}]
      message = Composer.Error.message(reason)
      assert message =~ "hex:oban  (local:g/plain)"
      assert message =~ "hex:oban --x  (local:g/argv)"

      assert {:error, {:conflicting_install, "oban", [{_, "hex:oban (path ../a)"}, _]}} =
               resolve(books, "local:g/source")

      # Strict: both flags may be on at once, and :all checks every path.
      assert {:error, {:conflicting_install, "oban", _}} = resolve(books, "local:g/flags")

      assert {:error, {:conflicting_install, "oban", [{nil, _}, {nil, _}]} = reason} =
               Resolver.resolve_steps(books, ["hex:oban", "hex:oban@1.0"])

      assert Composer.Error.message(reason) =~ "(the command line)"
    end

    test "package options on an unqualified name that is a step are an error", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s([{"ash/postgres", path: "../x", if: :x}])})

      assert {:error,
              {:dep_opts_on_step, "ash/postgres", "fake_book:ash/postgres", "local:g/p", [:path]} =
                reason} = resolve(books, "local:g/p")

      assert Composer.Error.message(reason) =~ "names the step fake_book:ash/postgres"
    end

    test "an @ source and a keyword source conflict", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s([{"hex:ash@3.5", version: "~> 3.5"}])})
      assert {:error, {:source_conflict, "local:g/p", _}} = resolve(books, "local:g/p")
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
        meta: %Composer.Step.Meta{requires: ["hex:my_lib"]}
      }

      refute Enum.any?(Resolver.warnings([install, needs]), &(elem(&1, 0) == :requires_order))
      assert [{:requires_order, _, "hex:my_lib"}] = Resolver.warnings([needs])
    end
  end

  describe "recipes" do
    test "{:use, ...} expands in place, nested, across cookbooks", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/a" => ~s([{:use, "b"}, "core:setup/sort_deps"]),
          "g/b" => ~s(["core:setup/credo", {:use, "fake_book:main/base"}])
        })

      assert {:ok, result} = resolve(books, "local:g/a")

      assert refs({:ok, result}) == [
               "core:setup/credo",
               "fake_book:hello",
               "core:setup/sort_deps"
             ]

      assert Enum.map(result.steps, & &1.origin) == [
               "local:g/b",
               "fake_book:main/base",
               "local:g/a"
             ]
    end

    test "an unqualified CLI recipe reference finds local recipes", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/mine" => ~s(["core:setup/credo"])})
      assert {:ok, %{root: "local:g/mine"}} = resolve(books, "g/mine", context: "core")
    end

    test "an ambiguous recipe reference lists the candidates", %{tmp_dir: dir} do
      books = cookbooks(dir)

      assert {:error,
              {:ambiguous, :recipe, "main/base", nil,
               ["fake_book:main/base", "other_book:main/base"]}} =
               resolve(books, "main/base")
    end

    test "a diamond expands once and is not a cycle", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/top" => ~s([{:use, "left"}, {:use, "right"}]),
          "g/left" => ~s([{:use, "shared"}, "core:setup/credo"]),
          "g/right" => ~s([{:use, "shared"}, "core:setup/quokka"]),
          "g/shared" => ~s(["core:setup/gitignore"])
        })

      assert refs(resolve(books, "local:g/top")) == [
               "core:setup/gitignore",
               "core:setup/credo",
               "core:setup/quokka"
             ]
    end

    test "duplicates are dropped on the resolved id, first wins", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/p" => ~s(["core:setup/gitignore", "setup/gitignore", {"setup/gitignore", if: :x}])
        })

      assert {:ok, result} = resolve(books, "local:g/p")
      assert refs({:ok, result}) == ["core:setup/gitignore", "core:setup/gitignore"]
      assert Enum.map(result.steps, & &1.if) == [nil, :x]
      assert [%{label: "core:setup/gitignore", if: nil}] = result.duplicates
    end

    test "{:task, ...} and {:queue, ...} are leaves", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s([{:task, "a.b", ["x"]}, {:queue, "c.d", [], if: :q}])})

      assert {:ok, %{steps: [task, queue]}} = resolve(books, "local:g/p")
      assert task.step == {:task, "a.b", ["x"]}
      assert queue.step == {:queue, "c.d", []}
      assert queue.if == :q
    end
  end

  describe "groups" do
    test "an unqualified {:use, name} is the recipe in the same group", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "ash/base" => ~s(["core:setup/credo"]),
          "ash/ecto" => ~s([{:use, "base"}, "core:setup/gitignore"]),
          "lv/base" => ~s(["core:setup/quokka"]),
          "lv/app" => ~s([{:use, "base"}, {:use, "ash/ecto"}])
        })

      assert {:ok, result} = resolve(books, "local:lv/app")

      assert refs({:ok, result}) == [
               "core:setup/quokka",
               "core:setup/credo",
               "core:setup/gitignore"
             ]

      assert Enum.map(result.recipes, & &1.ref) ==
               ["local:lv/app", "local:lv/base", "local:ash/ecto", "local:ash/base"]
    end

    test "an unqualified name missing from the group fails, suggesting its siblings", %{
      tmp_dir: dir
    } do
      books =
        cookbooks(dir, %{
          "ash/base" => ~s(["core:setup/credo"]),
          "ash/ecto" => ~s([{:use, "bsae"}]),
          "lv/base" => ~s(["core:setup/quokka"])
        })

      assert {:error, {:missing_recipe, "bsae", "local:ash/ecto", ["local:ash/base"]} = reason} =
               resolve(books, "local:ash/ecto")

      assert Composer.Error.message(reason) =~ "refers to a recipe in the same group"

      # fake_book:main/base exists, but an ungrouped name never leaves the group.
      books = cookbooks(dir, %{"main/x" => ~s([{:use, "nope"}])})

      assert {:error, {:missing_recipe, "nope", "local:main/x", _}} =
               resolve(books, "local:main/x")
    end

    test "a same-group cycle reports its path", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/a" => ~s([{:use, "b"}]), "g/b" => ~s([{:use, "a"}])})

      assert {:error, {:cycle, ["local:g/a", "local:g/b", "local:g/a"]}} =
               resolve(books, "local:g/a")
    end

    test "an ungrouped CLI reference names no recipe", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/mine" => ~s(["core:setup/credo"])})

      assert {:error, {:missing_recipe, "mine", nil, ["local:g/mine"]} = reason} =
               resolve(books, "mine")

      assert Composer.Error.message(reason) =~ ~s("cookbook:group/name")
    end

    test "declared_flags/1 is the union over every recipe reached", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "recipes"))

      File.write!(Path.join(dir, "recipes/g.exs"), """
      [
        app: [shortdoc: "App", flags: [own: "Own"], steps: [{:use, "deploy", if: :own}]],
        deploy: [shortdoc: "Deploy", flags: [gigalixir: "Gigalixir"], steps: [{"core:cluster/gigalixir", if: :gigalixir}]]
      ]
      """)

      {:ok, books} = Discovery.cookbooks(apps: [], config: dir)
      {:ok, result} = resolve(books, "local:g/app")
      assert Resolver.declared_flags(result) == [own: "Own", gigalixir: "Gigalixir"]
    end

    test "a group file that fails to load names the file", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "recipes"))
      File.write!(Path.join(dir, "recipes/g.exs"), "[a: [shortdoc: \"A\", steps: [], extra: 1]]")
      {:ok, books} = Discovery.cookbooks(apps: [], config: dir)

      assert {:error, {:unknown_recipe_key, "local:g/a", :extra}} = resolve(books, "local:g/a")
    end
  end

  describe "flags" do
    setup %{tmp_dir: dir} do
      %{
        books:
          cookbooks(dir, %{
            "g/app" =>
              ~s([{:use, "base"}, {:use, "deploy", if: :deploy}, {"core:setup/credo", if: :credo}]),
            "g/base" => ~s(["core:setup/gitignore"]),
            "g/deploy" => ~s(["core:cluster/gigalixir", {:use, "cluster", if: :cluster}]),
            "g/cluster" => ~s(["core:cluster/libcluster"]),
            "g/late" => ~s([{:use, "deploy", if: :deploy}, {:use, "deploy"}])
          })
      }
    end

    test "a gated include follows its flag", %{books: books} do
      assert refs(resolve(books, "local:g/app", flags: [deploy: true])) ==
               ["core:setup/gitignore", "core:cluster/gigalixir", "core:setup/credo"]

      assert refs(resolve(books, "local:g/app", flags: [])) == [
               "core:setup/gitignore",
               "core:setup/credo"
             ]
    end

    test ":all follows every gate and records it; nested gates accumulate", %{books: books} do
      assert {:ok, result} = resolve(books, "local:g/app")
      assert Resolver.flags(result) == [:deploy, :cluster, :credo]

      assert List.last(Enum.filter(result.steps, &(&1.ref == "core:cluster/libcluster"))).gates ==
               [
                 :deploy,
                 :cluster
               ]
    end

    test "a gated-off include still expands through a later ungated use", %{books: books} do
      assert refs(resolve(books, "local:g/late", flags: [])) == ["core:cluster/gigalixir"]
    end

    test "active/2 drops entries whose own if: is off", %{books: books} do
      {:ok, result} = resolve(books, "local:g/app", flags: [])
      assert refs(Resolver.active(result.steps, [])) == ["core:setup/gitignore"]

      assert refs(Resolver.active(result.steps, credo: true)) == [
               "core:setup/gitignore",
               "core:setup/credo"
             ]
    end
  end

  describe "errors" do
    test "cycles report the full path, across cookbooks", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/a" => ~s([{:use, "b"}]),
          "g/b" => ~s([{:use, "c"}]),
          "g/c" => ~s([{:use, "local:g/a"}]),
          "g/self" => ~s([{:use, "self"}])
        })

      assert {:error, {:cycle, ["local:g/a", "local:g/b", "local:g/c", "local:g/a"]}} =
               resolve(books, "local:g/a")

      assert {:error, {:cycle, ["local:g/self", "local:g/self"]}} = resolve(books, "local:g/self")

      assert Composer.Error.message({:cycle, ["local:g/a", "local:g/b", "local:g/a"]}) =~
               "local:g/a -> local:g/b"
    end

    test "a cycle hidden behind a gate is caught by flags: :all", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/a" => ~s([{:use, "b", if: :x}]), "g/b" => ~s([{:use, "a"}])})
      assert {:ok, _} = resolve(books, "local:g/a", flags: [])
      assert {:error, {:cycle, _}} = resolve(books, "local:g/a")
    end

    test "a missing include names the recipe", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/a" => ~s([{:use, "nope", if: :x}])})
      assert {:ok, _} = resolve(books, "local:g/a", flags: [])
      assert {:error, {:missing_recipe, "nope", "local:g/a", _}} = resolve(books, "local:g/a")
    end

    test "old forms are rejected", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/a" => "[{:add, :credo}]"})

      assert {:error, {:legacy_form, "local:g/a", {:add, :credo}, ~s("credo")}} =
               resolve(books, "local:g/a")
    end

    test "local cookbook steps are rejected", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/a" => ~s(["local:g/x"])})
      assert {:error, {:local_step, "local:g/x", "local:g/a"}} = resolve(books, "local:g/a")
    end

    test "validate_all/2 checks every recipe, optionally of some cookbooks", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/broken" => ~s([{:use, "missing"}])})

      assert {:error, {:missing_recipe, "missing", "local:g/broken", _}} =
               Resolver.validate_all(books)

      assert :ok = Resolver.validate_all(books, only: ["fake_book", "other_book"])
    end
  end

  describe "warnings/1" do
    test "phase order, provides overlaps, conflicts and requires order", %{tmp_dir: dir} do
      books =
        cookbooks(dir, %{
          "g/p" => ~s(["fake_book:ash/postgres", "fake_book:sqlite", "fake_book:hello"])
        })

      {:ok, %{steps: entries}} = resolve(books, "local:g/p")

      warnings = Resolver.warnings(entries)
      messages = Enum.map(warnings, &Composer.Error.warning/1)

      assert {:phase_order, %{ref: "fake_book:sqlite"}, %{ref: "fake_book:ash/postgres"}} =
               Enum.find(warnings, &(elem(&1, 0) == :phase_order))

      assert Enum.any?(
               messages,
               &(&1 =~ "fake_book:ash/postgres, fake_book:sqlite all provide :datalayer")
             )

      assert Enum.any?(
               messages,
               &(&1 =~
                   "fake_book:sqlite conflicts with :datalayer, which fake_book:ash/postgres provides")
             )

      assert Enum.any?(
               messages,
               &(&1 =~
                   "fake_book:ash/postgres requires fake_book:hello, which is not listed before it")
             )
    end

    test "a requirement listed earlier is satisfied", %{tmp_dir: dir} do
      books = cookbooks(dir, %{"g/p" => ~s(["fake_book:hello", "fake_book:ash/postgres"])})
      {:ok, %{steps: entries}} = resolve(books, "local:g/p")
      refute Enum.any?(Resolver.warnings(entries), &(elem(&1, 0) == :requires_order))
    end
  end

  describe "cookbook aliases" do
    # A local group file `g.exs` with the given recipes source.
    defp aliased(dir, source) do
      path = Path.join([dir, "recipes", "g.exs"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
      {:ok, cookbooks} = Discovery.cookbooks(apps: [:fake_book, :other_book], config: dir)
      cookbooks
    end

    test "an aliased step or include resolves like the qualified form", %{tmp_dir: dir} do
      books =
        aliased(dir, """
        [
          aliased: [
            shortdoc: "x",
            aliases: [fb: "fake_book", ob: "other_book"],
            steps: ["fb:ash/postgres", {:use, "ob:main/shared"}]
          ],
          qualified: [
            shortdoc: "x",
            steps: ["fake_book:ash/postgres", {:use, "other_book:main/shared"}]
          ]
        ]
        """)

      assert {:ok, aliased} = resolve(books, "local:g/aliased")
      assert {:ok, qualified} = resolve(books, "local:g/qualified")

      strip = fn result -> Enum.map(result.steps, &Map.take(&1, [:ref, :label, :step])) end
      assert strip.(aliased) == strip.(qualified)
      assert [%{alias: "fb"}, %{alias: nil} | _] = aliased.steps
      assert "other_book:main/shared" in Enum.map(aliased.recipes, & &1.ref)
    end

    test "an alias does not apply inside an included recipe", %{tmp_dir: dir} do
      books =
        aliased(dir, """
        [
          a: [shortdoc: "x", aliases: [fb: "fake_book"], steps: ["fb:hello", {:use, "b"}]],
          b: [shortdoc: "x", steps: ["fb:hello"]]
        ]
        """)

      assert {:error, {:unknown_cookbook, "fb", "fb:hello", "local:g/b", _} = reason} =
               resolve(books, "local:g/a")

      assert Composer.Error.message(reason) =~ "declare it in local:g/b's aliases:"
    end

    test "an alias does not apply on the command line", %{tmp_dir: dir} do
      books = aliased(dir, ~s([a: [shortdoc: "x", aliases: [fb: "fake_book"], steps: []]]))

      assert {:error, {:unknown_cookbook, "fb", _, nil, _}} =
               Resolver.resolve_steps(books, ["fb:hello"])
    end

    test "an alias may not shadow an installed cookbook", %{tmp_dir: dir} do
      books =
        aliased(dir, ~s([a: [shortdoc: "x", aliases: [other_book: "fake_book"], steps: []]]))

      assert {:error, {:alias_shadows_cookbook, "local:g/a", :other_book}} =
               resolve(books, "local:g/a")
    end

    test "errors name both the alias and its target", %{tmp_dir: dir} do
      books =
        aliased(dir, """
        [
          missing: [shortdoc: "x", aliases: [lab: "cc_lab"], steps: ["lab:auth/passkeys"]],
          no_step: [shortdoc: "x", aliases: [fb: "fake_book"], steps: ["fb:nope/nothing"]]
        ]
        """)

      assert {:error, reason} = resolve(books, "local:g/missing")
      assert {:unknown_alias_target, "lab:auth/passkeys", "lab", "cc_lab", _, _} = reason

      assert Composer.Error.message(reason) =~
               "lab:auth/passkeys (lab = cc_lab): cookbook cc_lab not found"

      assert {:error, {:via_alias, _, "fb", "fake_book", {:missing_step, _, _, _}} = reason} =
               resolve(books, "local:g/no_step")

      assert Composer.Error.message(reason) =~ ~s("fb:nope/nothing" uses the alias fb = fake_book)
    end
  end
end
