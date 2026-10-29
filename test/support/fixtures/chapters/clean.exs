# A clean chapter: every rule passes.
[
  base: [
    shortdoc: "The base",
    steps: ["cb_std:echo"]
  ],
  app: [
    shortdoc: "The app",
    doc: """
    Builds on clean/base.
    """,
    flags: [completions: "Add shell completion"],
    steps: ["./base", {"cb_std:completions:mix", if: :completions}]
  ]
]
