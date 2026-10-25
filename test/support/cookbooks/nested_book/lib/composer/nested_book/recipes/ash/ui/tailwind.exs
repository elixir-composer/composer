[
  base: [shortdoc: "Tailwind base", steps: [":cluster:dns"]],
  full: [
    shortdoc: "Everything, through relative includes",
    steps: ["./base", "./forms/inputs", "../buttons", "../../core"]
  ]
]
