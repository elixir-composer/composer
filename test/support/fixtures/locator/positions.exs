# Positions in this file are asserted by locator_test.exs: edit with care.
aliases = [lab: "cc_lab"]
shared = ["core:setup/gitignore"]
name = "dynamic"

[
  auth: [
    shortdoc: "Auth",
    aliases: aliases,
    flags: [credo: "Add Credo"],
    steps: [
      "lab:auth/passkeys",
      {"core:setup/credo",
       if: :credo},
      "lab:" <> name,
      {"hex:igniter",
       argv: ["--yes"]},
      {:use, "base"},
      "lab:auth/passkeys",
      "esc\"aped"
    ]
  ],
  base: [shortdoc: "é😀 é", steps: ["core:setup/sort_deps", {:use, "bound", if: :x}]],
  bound: [shortdoc: "Bound steps", steps: shared]
]
