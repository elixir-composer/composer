defmodule Mix.Tasks.Composer do
  @shortdoc "Lists composer's tasks"

  @moduledoc """
  Prints an overview of composer and lists its tasks, as `mix help` lists
  them: every loaded `composer.*` task with a shortdoc, including those of
  installed archives such as `mix composer.new`.

      $ mix composer
  """

  use Mix.Task

  @source_url Mix.Project.config()[:source_url]

  @impl Mix.Task
  def run(_argv) do
    Mix.shell().info("""
    Composer is an app generation tool for Elixir.
    #{@source_url}
    ----------------------------------------------
    #{table(tasks())}
    """)
  end

  @doc false
  # {task name, shortdoc} for every loaded composer.* task with a shortdoc,
  # sorted by name.
  def tasks do
    Mix.Task.load_all()

    for module <- Mix.Task.all_modules(),
        name = Mix.Task.task_name(module),
        String.starts_with?(name, "composer."),
        doc = Mix.Task.shortdoc(module),
        doc != nil do
      {name, doc}
    end
    |> Enum.sort()
  end

  defp table(tasks) do
    width = tasks |> Enum.map(fn {name, _doc} -> String.length(name) end) |> Enum.max(fn -> 0 end)

    Enum.map_join(tasks, "\n", fn {name, doc} ->
      "mix #{String.pad_trailing(name, width)} # #{doc}"
    end)
  end
end
