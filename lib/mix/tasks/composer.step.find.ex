defmodule Mix.Tasks.Composer.Step.Find do
  @shortdoc "Searches steps by id, summary and tags"

  @moduledoc """
  Searches step ids, summaries and tags, case-insensitively. Steps whose id
  matches come first.

      mix composer.step.find oban
      mix composer.step.find "tailwind" --json

  ## Options

    * `--json` - print JSON instead of text
  """

  use Mix.Task

  alias Composer.{CLI, Cookbook}

  @impl Mix.Task
  def run(argv) do
    {opts, args} = CLI.parse!(argv)

    query =
      case args do
        [] -> Mix.raise("Usage: mix composer.step.find QUERY")
        words -> words |> Enum.join(" ") |> String.downcase()
      end

    CLI.cookbooks!(quiet: opts[:json])
    |> Enum.flat_map(&Cookbook.steps/1)
    |> search(query)
    |> Mix.Tasks.Composer.Step.List.print(opts[:json])
  end

  @doc false
  # Ranks id matches before summary and tag matches, keeping list order
  # within each rank.
  def search(steps, query) do
    steps
    |> Enum.map(&{rank(&1, query), &1})
    |> Enum.reject(fn {rank, _meta} -> rank == nil end)
    |> Enum.sort_by(fn {rank, meta} -> {rank, meta.ref} end)
    |> Enum.map(&elem(&1, 1))
  end

  defp rank(meta, query) do
    cond do
      contains?(meta.ref, query) -> 0
      contains?(meta.summary, query) -> 1
      Enum.any?(meta.tags, &contains?(&1, query)) -> 2
      true -> nil
    end
  end

  defp contains?(nil, _query), do: false
  defp contains?(text, query), do: text |> String.downcase() |> String.contains?(query)
end
