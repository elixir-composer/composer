# A clean group: every rule passes.
[
  base: [
    shortdoc: "The base",
    steps: ["core:setup/gitignore"]
  ],
  app: [
    shortdoc: "The app",
    doc: """
    Builds on clean/base.
    """,
    flags: [credo: "Add Credo"],
    steps: [{:use, "base"}, {"core:setup/credo", if: :credo}]
  ]
]
