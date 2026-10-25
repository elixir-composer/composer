[
  # Shares its id with fake_book/main/base.
  base: [shortdoc: "Other base", steps: [":hello"]],
  shared: [shortdoc: "Uses fake_book", steps: ["fake_book/main/base", ":hello"]]
]
