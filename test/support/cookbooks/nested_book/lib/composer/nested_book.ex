defmodule Composer.NestedBook do
  @moduledoc false
  # Nested chapters: recipes/ash.exs, recipes/ash/ui.exs,
  # recipes/ash/ui/tailwind.exs and recipes/ash/ui/tailwind/forms.exs.
  use Composer.Cookbook, app: :nested_book, summary: "A fixture cookbook with nested chapters"
end
