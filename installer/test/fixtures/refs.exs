# Addresses and how they parse, shared by ComposerNew.Ref (this project's
# test/composer_new/ref_test.exs) and Composer.Ref (composer's
# test/composer/ref_fixture_test.exs), so the two parsers can't drift.
#
# Each entry is {address, {:ok, fields}} or {address, :error}, where fields
# are kind, scope, cookbook, up, segments and source. An optional third
# element marks a case only one parser accepts: :archive (a recipe with an
# @ source, which names where the archive installs the cookbook from) or
# :composer. The other parser must reject it.
#
# Only grammar rules both parsers share belong here; the archive-only
# rules (qualified recipes only, no hex:, no cb_std@source) are tested in
# the archive.
recipe = fn cookbook, segments, source ->
  {:ok,
   %{
     kind: :recipe,
     scope: :qualified,
     cookbook: cookbook,
     up: 0,
     segments: segments,
     source: source
   }}
end

step = fn cookbook, segments, source ->
  {:ok,
   %{
     kind: :step,
     scope: :qualified,
     cookbook: cookbook,
     up: 0,
     segments: segments,
     source: source
   }}
end

base = &recipe.("cb_lab", ["lv", "base"], &1)

[
  # qualified recipes, nested chapter paths
  {"cb_lab/lv/base", base.([])},
  {"cb_std/debug/echo", recipe.("cb_std", ["debug", "echo"], [])},
  {"cb_lab/ash/ui/tailwind/base", recipe.("cb_lab", ["ash", "ui", "tailwind", "base"], [])},

  # qualified steps, multi-segment
  {"cb_std:setup:credo", step.("cb_std", ["setup", "credo"], [])},
  {"cb_std:cluster:gigalixir:libcluster",
   step.("cb_std", ["cluster", "gigalixir", "libcluster"], [])},
  {"cb_std:echo", step.("cb_std", ["echo"], [])},

  # root and relative recipes, root steps
  {"/ash/ui/buttons",
   {:ok,
    %{
      kind: :recipe,
      scope: :root,
      cookbook: nil,
      up: 0,
      segments: ["ash", "ui", "buttons"],
      source: []
    }}},
  {":setup:credo",
   {:ok,
    %{kind: :step, scope: :root, cookbook: nil, up: 0, segments: ["setup", "credo"], source: []}}},
  {"./base",
   {:ok, %{kind: :recipe, scope: :relative, cookbook: nil, up: 0, segments: ["base"], source: []}}},
  {"./forms/inputs",
   {:ok,
    %{
      kind: :recipe,
      scope: :relative,
      cookbook: nil,
      up: 0,
      segments: ["forms", "inputs"],
      source: []
    }}},
  {"../buttons",
   {:ok,
    %{kind: :recipe, scope: :relative, cookbook: nil, up: 1, segments: ["buttons"], source: []}}},
  {"../../../core",
   {:ok, %{kind: :recipe, scope: :relative, cookbook: nil, up: 3, segments: ["core"], source: []}}},

  # a bare name is a search
  {"libcluster",
   {:ok, %{kind: nil, scope: :search, cookbook: nil, up: 0, segments: ["libcluster"], source: []}}},

  # - is normalized to _, in the name only
  {"cb-lab/lv/daisy-ui", recipe.("cb_lab", ["lv", "daisy_ui"], [])},
  {"hex:live-debugger@github:software-mansion/live-debugger",
   step.("hex", ["live_debugger"], github: "software-mansion/live-debugger")},
  {"cb-lab/lv/base@path:../cb-lab", base.(path: "../cb-lab"), :archive},

  # hex:, with a private repo and @ sources
  {"hex:oban", step.("hex", ["oban"], [])},
  {"hex:oban.oban_pro", step.("hex", ["oban.oban_pro"], [])},
  {"hex:ash@3.5", step.("hex", ["ash"], version: "~> 3.0")},
  {"hex:my_lib@path:../my_lib", step.("hex", ["my_lib"], path: "../my_lib")},

  # recipe sources: versions
  {"cb_lab/lv/base@3.5.0", base.(version: "== 3.5.0"), :archive},
  {"cb_lab/lv/base@3.5", base.(version: "~> 3.0"), :archive},
  {"cb_lab/lv/base@3", base.(version: "~> 3.0"), :archive},
  {"cb_lab/lv/base@0.5", base.(version: "~> 0.5"), :archive},
  {"cb_lab/lv/base@~> 3.5", base.(version: "~> 3.5"), :archive},
  {"cb_lab/lv/base@>= 1.0.0", base.(version: ">= 1.0.0"), :archive},
  {"cb_lab/lv/base@1.0.0-rc.1", base.(version: "== 1.0.0-rc.1"), :archive},

  # github:, with and without a git ref
  {"cb_lab/lv/base@github:elixir-composer/cb_lab", base.(github: "elixir-composer/cb_lab"),
   :archive},
  {"cb_lab/lv/base@github:elixir-composer/cb_lab@v0.3.0",
   base.(github: "elixir-composer/cb_lab", ref: "v0.3.0"), :archive},

  # git: URLs may contain @ and :
  {"cb_lab/lv/base@git:git@github.com:elixir-composer/cb_lab.git",
   base.(git: "git@github.com:elixir-composer/cb_lab.git"), :archive},
  {"cb_lab/lv/base@git:https://example.com/cb_lab.git",
   base.(git: "https://example.com/cb_lab.git"), :archive},

  # path:
  {"cb_home/lv/base@path:~/src/Gen/cb_home",
   recipe.("cb_home", ["lv", "base"], path: "~/src/Gen/cb_home"), :archive},
  {"cb_home/lv/base@path:/abs/cb_home", recipe.("cb_home", ["lv", "base"], path: "/abs/cb_home"),
   :archive},

  # errors: sources
  {"cb_lab/lv/base@", :error},
  {"cb_lab/lv/base@path:", :error},
  {"cb_lab/lv/base@github:", :error},
  {"cb_lab/lv/base@git:", :error},
  {"cb_lab/lv/base@github:nobody", :error},
  {"cb_lab/lv/base@github:o/r@", :error},
  {"cb_lab/lv/base@svn:x", :error},
  {"cb_lab/lv/base@not a version", :error},
  {"cb_std:setup:credo@1.0", :error},
  {"oban@2.0", :error},

  # errors: grammar
  {"cb_lab:lv/base", :error},
  {"cb_std/ash:postgres", :error},
  {"./a/../b", :error},
  {"a/./b", :error},
  {".:dns", :error},
  {"..:aws:dns", :error},
  {"hex/oban", :error},
  {"hex:a:b", :error},
  {"Cb/lv/base", :error},
  {"cb_lab/Lv/base", :error},
  {"cb_lab/lv//base", :error},
  {"cb_lab/lv/", :error},
  {"", :error},
  {"x y", :error}
]
