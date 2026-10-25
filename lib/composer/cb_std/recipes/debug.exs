# cb_std's debugging recipes: cb_std/debug/<name>.
[
  echo: [
    shortdoc: "Shows how to print messages with cb_std:echo",
    doc: """
    cb_std:echo prints its message to stdout and changes nothing, so it can
    mark where a recipe run has got to. Pass the message with argv:.
    Include this recipe with "cb_std/debug/echo", or copy its steps.
    """,
    steps: [
      {"cb_std:echo", argv: ["Starting the cb_std/debug/echo recipe"]},
      {"cb_std:echo", argv: ["Words", "are", "joined", "with", "spaces"]},
      {"cb_std:echo", argv: ["Finished the cb_std/debug/echo recipe"]}
    ]
  ]
]
