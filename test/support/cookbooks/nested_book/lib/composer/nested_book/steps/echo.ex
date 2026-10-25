defmodule Composer.NestedBook.Steps.Echo do
  @moduledoc false
  # Shares its name with no recipe: nested_book/echo is a kind mismatch.
  use Composer.Step, summary: "Writes echo.txt", action: :gen, stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter), do: Igniter.create_new_file(igniter, "echo.txt", "echo\n")
end
