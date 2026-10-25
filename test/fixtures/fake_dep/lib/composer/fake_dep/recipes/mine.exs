[
  base: [shortdoc: "Says hi", steps: ["fake_dep:hi"]],
  app: [
    shortdoc: "Base, plus a .gitignore with --ignore",
    flags: [ignore: "Add macOS files to .gitignore"],
    steps: ["./base", {"cb_std:setup:gitignore", if: :ignore}]
  ]
]
