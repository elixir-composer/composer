defmodule Composer.OtherBook.Steps.Hello do
  @moduledoc false
  # Shares its id with fake_book:hello.
  use Composer.Step, summary: "Writes other.txt", action: :gen, stability: :stable

  @impl Igniter.Mix.Task
  def igniter(igniter), do: Igniter.create_new_file(igniter, "other.txt", "other\n")
end
