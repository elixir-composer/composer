# cb_std/completions recipes
[
  # cb_std/completions/install
  install: [
    shortdoc: "Installs shell completion for mix and composer",
    doc: """
    Installs the mix_completions archive and caches the project's mix tasks
    (cb_std:completions:mix), then installs composer's bash completion script
    (cb_std:completions:composer). Both write to ~/.complete, outside the
    project; see the completion guide. Run cb_std:completions:composer with
    --shell zsh or --shell fish for those shells.
    """,
    steps: [
      "cb_std:completions:mix",
      "cb_std:completions:composer"
    ]
  ]
]
