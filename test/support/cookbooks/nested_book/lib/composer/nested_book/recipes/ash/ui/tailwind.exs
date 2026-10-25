[
  base: [shortdoc: "Tailwind base", steps: ["nested_book:cluster/dns"]],
  full: [
    shortdoc: "Everything, through relative includes",
    steps: [
      {:use, "base"},
      {:use, "nested_book:ash/ui/tailwind/forms/inputs"},
      {:use, "nested_book:ash/ui/buttons"},
      {:use, "nested_book:ash/core"}
    ]
  ]
]
