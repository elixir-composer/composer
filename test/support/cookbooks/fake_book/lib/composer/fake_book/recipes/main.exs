# The main fixture chapter.
[
  base: [
    shortdoc: "The base recipe",
    doc: "Writes hello.txt.",
    steps: [":hello"]
  ],
  full: [
    shortdoc: "An app recipe",
    flags: [credo: "Add Credo", extra: "Add the extra steps"],
    steps: [
      "./base",
      ":ash:postgres",
      {":setup:credo", if: :credo},
      {"/nested/extra", if: :extra},
      {:queue, "foo.bar", []}
    ]
  ]
]
