[
  base: [shortdoc: "Says hi", steps: ["fake_dep:hi"]],
  app: [
    shortdoc: "Base, plus a message with --shout",
    flags: [shout: "Print a message from cb_std:echo"],
    steps: ["./base", {"cb_std:echo", if: :shout, argv: ["Shouting from fake_dep"]}]
  ]
]
