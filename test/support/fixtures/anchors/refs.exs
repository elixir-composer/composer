# Every reference problem lint reports; none may be placed on line 1.
aliases = [fb: "fake_book", gone: "not_installed", ob: "other_book"]

[
  bad: [
    shortdoc: "x",
    aliases: aliases,
    steps: [
      "cb_std:setup:credoo",
      "credoo",
      "nope:x",
      "mine:x",
      "hello",
      {"setup/gitignore", only: :dev},
      "gone:x",
      "fb:nope",
      "a/b:c",
      "ob:hello",
      "cb_std:setup/credo",
      "fake_book/hello",
      ".:dns",
      "../../x",
      {"fake_book/main/base", argv: ["x"]}
    ]
  ],
  uses: [shortdoc: "x", steps: [{:use, "nope"}, "/refs/nope"]],
  shadow: [shortdoc: "x", aliases: [other_book: "fake_book"], steps: ["other_book:hello"]],
  unused: [shortdoc: "x", aliases: [fb: "other_book"], steps: []],
  install: [shortdoc: "x", steps: ["hex:oban", {"hex:oban", argv: ["--x"]}]],
  loop_a: [shortdoc: "x", steps: ["./loop_b"]],
  loop_b: [shortdoc: "x", steps: ["./loop_a"]]
]
