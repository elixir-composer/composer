# Positions in this file are asserted by locator_test.exs: edit with care.
aliases = [lab: "cc_lab"]
shared = ["cb_std:setup/gitignore"]
name = "dynamic"

[
  auth: [
    shortdoc: "Auth",
    aliases: aliases,
    flags: [credo: "Add Credo"],
    steps: [
      "lab:auth/passkeys",
      {"cb_std:setup/credo",
       if: :credo},
      "lab:" <> name,
      {"hex:igniter",
       argv: ["--yes"]},
      {:use, "base"},
      "lab:auth/passkeys",
      "esc\"aped"
    ]
  ],
  base: [shortdoc: "é😀 é", steps: ["cb_std:setup/sort_deps", {:use, "bound", if: :x}]],
  bound: [shortdoc: "Bound steps", steps: shared]
]
