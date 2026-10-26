# Every recipe-shape problem lint reports; none may be placed on line 1.
[
  no_shortdoc: [steps: []],
  unknown_key: [shortdoc: "x", help: "y", steps: []],
  bad_value: [shortdoc: "x", flags: "nope", steps: []],
  undeclared: [shortdoc: "x", steps: [{"cb_std:setup:credo", if: :credo}]],
  multiline: [shortdoc: "one\ntwo", steps: []],
  shape: "not a keyword list",
  "Bad-Name": [shortdoc: "x", steps: []],
  dup: [shortdoc: "x", steps: []],
  dup: [shortdoc: "y", steps: []],
  bad_aliases: [
    shortdoc: "x",
    aliases: ["Bad-Alias": "fake_book", cb_std: "fake_book", fb: "fake_book", fb: "fake_book"],
    steps: []
  ],
  bad_targets: [shortdoc: "x", aliases: [at: :fake_book, tgt: "cb_std"], steps: []],
  entries: [
    shortdoc: "x",
    steps: [
      {:remove, :daisy_ui},
      {:nope},
      {"cb_std:setup:credo", nope: 1},
      {"cb_std:setup:credo", if: "x"},
      {"cb_std:setup:credo", only: :dev},
      {"hex:a", version: "~> 1.0", path: "../a"},
      {"hex:a", branch: "main"},
      {"hex:a", github: "o/a", branch: "x", tag: "y"},
      {"hex:a@~> 1.0", version: "~> 1.0"},
      {"hex:org.a", path: "../a"},
      {"a:b:c", if: :x}
    ]
  ],
  reserved: [shortdoc: "x", flags: [yes: "Y"], steps: []]
]
