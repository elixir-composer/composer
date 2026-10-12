# Templates live beside their steps and are copied into other projects
# verbatim (or rendered with EEx), so they are left exactly as written. No
# step is an .exs file, so every .exs under steps/ is a template.
# test/support/fixtures holds deliberately broken recipes.
templates =
  Enum.flat_map(
    ["lib/composer/*/steps/**/*.exs", "test/support/cookbooks/*/lib/composer/*/steps/**/*.exs"],
    &Path.wildcard(&1, match_dot: true)
  )

[
  inputs:
    Enum.flat_map(
      [
        "{mix,.formatter}.exs",
        "{config,lib}/**/*.{ex,exs}",
        "test/*.exs",
        "test/{composer,mix}/**/*.exs",
        "test/support/*.ex",
        "test/support/cookbooks/**/*.{ex,exs}"
      ],
      &Path.wildcard(&1, match_dot: true)
    ) -- templates
]
