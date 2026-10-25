# An old-syntax chapter, rewritten by mix composer.cookbook.lint --fix.
aliases = [fb: "fake_book"]

[
  base: [
    shortdoc: "The base",
    # A step in the old syntax, and a bare package name.
    steps: ["cb_std:setup/gitignore", "oban"]
  ],
  app: [
    shortdoc: "The app",
    aliases: aliases,
    flags: [credo: "Add Credo", x: "X"],
    steps: [
      {:use, "base"},   # the same chapter
      {:use, "base",
       if: :x},
      {:use, "fake_book:main/base"},
      {:use, "main/full"},
      {"cb_std:setup/credo", if: :credo},
      "ash/postgres",
      "fb:ash/postgres",
      # Ambiguous, so reported rather than guessed:
      "setup/credo",
      {:use, "main/base"},
      "hex:igniter"
    ]
  ]
]
