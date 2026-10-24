# The main fixture group.
[
  base: [
    shortdoc: "The base recipe",
    doc: "Writes hello.txt.",
    steps: ["hello"]
  ],
  full: [
    shortdoc: "An app recipe",
    flags: [credo: "Add Credo", extra: "Add the extra steps"],
    steps: [
      {:use, "base"},
      "ash/postgres",
      {"cb_std:setup/credo", if: :credo},
      {:use, "nested/extra", if: :extra},
      {:queue, "foo.bar", []}
    ]
  ]
]
