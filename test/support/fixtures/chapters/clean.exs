# A clean chapter: every rule passes.
[
  base: [
    shortdoc: "The base",
    steps: ["cb_std:setup:gitignore"]
  ],
  app: [
    shortdoc: "The app",
    doc: """
    Builds on clean/base.
    """,
    flags: [credo: "Add Credo"],
    steps: ["./base", {"cb_std:setup:credo", if: :credo}]
  ]
]
