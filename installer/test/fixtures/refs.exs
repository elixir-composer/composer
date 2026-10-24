# Reference strings and how they parse, shared by ComposerNew.Ref (this
# project's test/composer_new/ref_test.exs) and Composer.Ref (composer's
# test/composer/ref_fixture_test.exs), so the two parsers can't drift.
#
# Each entry is {ref, {:ok, cookbook, path, source}} or {ref, :error}.
# Composer.Ref reads the name before the first @ as a reference, and the
# spec after it as the source of a hex:<cookbook>@<spec> reference.
#
# Only rules both parsers share belong here; the archive-only rules
# (qualified refs, no hex:, no cb_std@source) are tested in the archive.
[
  # no source: the latest hex release
  {"cb_lab:lv/base", {:ok, "cb_lab", "lv/base", []}},
  {"cb_std:debug/echo", {:ok, "cb_std", "debug/echo", []}},
  {"cb_lab:a/b/c", {:ok, "cb_lab", "a/b/c", []}},

  # - is normalized to _, in the name only
  {"cb-lab:lv/daisy-ui", {:ok, "cb_lab", "lv/daisy_ui", []}},
  {"cb-lab:lv/base@path:../cb-lab", {:ok, "cb_lab", "lv/base", [path: "../cb-lab"]}},

  # versions
  {"cb_lab:lv/base@3.5.0", {:ok, "cb_lab", "lv/base", [version: "== 3.5.0"]}},
  {"cb_lab:lv/base@3.5", {:ok, "cb_lab", "lv/base", [version: "~> 3.0"]}},
  {"cb_lab:lv/base@3", {:ok, "cb_lab", "lv/base", [version: "~> 3.0"]}},
  {"cb_lab:lv/base@0.5", {:ok, "cb_lab", "lv/base", [version: "~> 0.5"]}},
  {"cb_lab:lv/base@~> 3.5", {:ok, "cb_lab", "lv/base", [version: "~> 3.5"]}},
  {"cb_lab:lv/base@>= 1.0.0", {:ok, "cb_lab", "lv/base", [version: ">= 1.0.0"]}},
  {"cb_lab:lv/base@1.0.0-rc.1", {:ok, "cb_lab", "lv/base", [version: "== 1.0.0-rc.1"]}},

  # github:, with and without a git ref
  {"cb_lab:lv/base@github:elixir-composer/cb_lab",
   {:ok, "cb_lab", "lv/base", [github: "elixir-composer/cb_lab"]}},
  {"cb_lab:lv/base@github:elixir-composer/cb_lab@v0.3.0",
   {:ok, "cb_lab", "lv/base", [github: "elixir-composer/cb_lab", ref: "v0.3.0"]}},

  # git: URLs may contain @ and :
  {"cb_lab:lv/base@git:git@github.com:elixir-composer/cb_lab.git",
   {:ok, "cb_lab", "lv/base", [git: "git@github.com:elixir-composer/cb_lab.git"]}},
  {"cb_lab:lv/base@git:https://example.com/cb_lab.git",
   {:ok, "cb_lab", "lv/base", [git: "https://example.com/cb_lab.git"]}},

  # path:
  {"cb_home:lv/base@path:~/src/Gen/cb_home",
   {:ok, "cb_home", "lv/base", [path: "~/src/Gen/cb_home"]}},
  {"cb_home:lv/base@path:/abs/cb_home", {:ok, "cb_home", "lv/base", [path: "/abs/cb_home"]}},

  # errors
  {"cb_lab:lv/base@", :error},
  {"cb_lab:lv/base@path:", :error},
  {"cb_lab:lv/base@github:", :error},
  {"cb_lab:lv/base@git:", :error},
  {"cb_lab:lv/base@github:nobody", :error},
  {"cb_lab:lv/base@github:o/r@", :error},
  {"cb_lab:lv/base@svn:x", :error},
  {"cb_lab:lv/base@not a version", :error},
  {"Cb:lv/base", :error},
  {"cb_lab:Lv/base", :error},
  {"cb_lab:lv//base", :error},
  {"a:b:c", :error}
]
