defmodule Mix.Tasks.Composer.Step.Show do
  @shortdoc "Shows a step's metadata and what it changes"

  @moduledoc """
  Shows a step's summary, facets, `requires`, `provides` and `conflicts`,
  then dry-runs it against the current project to report the files it
  touches and the dependencies it adds. Nothing is written.

      mix composer.step.show cb_std:setup:credo
      mix composer.step.show ash/postgres --json

  The dry run stays offline (package versions fall back to permissive
  ranges). A step that cannot dry-run here still shows its metadata.

  ## Options

    * `--json` - print JSON instead of text
  """

  use Mix.Task

  alias Composer.{CLI, Resolver}
  alias Composer.Step.Meta

  @impl Mix.Task
  def run(argv) do
    {opts, args} = CLI.parse!(argv)

    ref =
      case args do
        [ref] -> ref
        _ -> Mix.raise("Usage: mix composer.step.show REF")
      end

    cookbooks = CLI.cookbooks!(quiet: opts[:json])

    case CLI.ok!(Resolver.find_step(cookbooks, ref, CLI.context(cookbooks))) do
      {:step, meta} ->
        dry_run = dry_run(meta.module)

        if opts[:json],
          do: CLI.json(Map.put(Meta.to_data(meta), "dry_run", dry_run)),
          else: print(meta, dry_run)

      {:hex, package} ->
        if opts[:json] do
          CLI.json(%{"ref" => "hex:" <> package, "hex" => package})
        else
          Mix.shell().info(Meta.hex_note(package))
        end
    end
  end

  defp print(meta, dry_run) do
    Mix.shell().info("#{meta.ref} - #{meta.summary || "(no summary)"}\n")

    meta
    |> Meta.rows()
    |> Enum.map(fn {label, value} -> [label <> ":", value] end)
    |> CLI.table()
    |> Mix.shell().info()

    case dry_run do
      %{"error" => error} ->
        Mix.shell().info("\nDry run unavailable: #{error}")

      %{"files" => files, "deps" => deps} ->
        Mix.shell().info("\nDry run against this project:")
        Mix.shell().info("  files: " <> list(files))
        Mix.shell().info("  deps added: " <> list(deps))
    end
  end

  defp list([]), do: "(none)"
  defp list(items), do: Enum.join(items, ", ")

  @doc false
  # Composes the step into a fresh igniter and reports what it would change.
  # Never applied, and offline: Composer.Versions falls back to permissive
  # ranges while it runs.
  def dry_run(module) do
    previous = Application.fetch_env(:composer, :fetch_versions)
    Application.put_env(:composer, :fetch_versions, false)

    try do
      if Mix.Project.get() == nil, do: raise("not inside a Mix project")

      igniter = Igniter.compose_task(Igniter.new(), module, [])

      changed =
        igniter.rewrite
        |> Rewrite.sources()
        |> Enum.filter(&(Rewrite.Source.updated?(&1) or Rewrite.Source.from?(&1, :string)))

      files =
        (Enum.map(changed, &Rewrite.Source.get(&1, :path)) ++
           Map.keys(igniter.moves) ++ igniter.rms)
        |> Enum.uniq()
        |> Enum.sort()

      %{"files" => files, "deps" => added_deps(changed)}
    rescue
      exception -> %{"error" => Exception.message(exception)}
    catch
      kind, reason -> %{"error" => Exception.format_banner(kind, reason)}
    after
      case previous do
        {:ok, value} -> Application.put_env(:composer, :fetch_versions, value)
        :error -> Application.delete_env(:composer, :fetch_versions)
      end
    end
  end

  defp added_deps(sources) do
    case Enum.find(sources, &(Rewrite.Source.get(&1, :path) == "mix.exs")) do
      nil ->
        []

      source ->
        before =
          if Rewrite.Source.from?(source, :string),
            do: "",
            else: Rewrite.Source.get(source, :content, 1)

        Enum.sort(dep_names(Rewrite.Source.get(source, :content)) -- dep_names(before))
    end
  end

  defp dep_names(content) do
    ~r/\{:([a-z0-9_]+),/
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end
end
