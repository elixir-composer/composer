# Core's debugging recipes: core:debug/<name>.
[
  echo: [
    shortdoc: "Shows how to print messages with core:echo",
    doc: """
    core:echo prints its message to stdout and changes nothing, so it can
    mark where a recipe run has got to. Pass the message with argv:.
    Include this recipe with {:use, "core:debug/echo"}, or copy its steps.
    """,
    steps: [
      {"core:echo", argv: ["Starting the core:debug/echo recipe"]},
      {"core:echo", argv: ["Words", "are", "joined", "with", "spaces"]},
      {"core:echo", argv: ["Finished the core:debug/echo recipe"]}
    ]
  ]
]
