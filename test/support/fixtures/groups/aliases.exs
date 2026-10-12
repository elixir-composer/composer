aliases = [fb: "fake_book"]

[
  base: [shortdoc: "Aliased step", aliases: aliases, steps: ["fb:hello"]],
  app: [shortdoc: "Aliased include", aliases: aliases, steps: [{:use, "fb:main/base"}]]
]
