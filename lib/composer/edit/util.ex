defmodule Composer.Edit.Util do
  @moduledoc """
  Conveniences for steps that don't edit a file's content directly.
  """

  @doc """
  Generates a migration with a unique timestamp.

  Ecto refuses to run duplicate migration versions, and a composer can create
  several within the same second, so the timestamp is advanced past every
  migration already present.
  """
  def gen_migration(igniter, repo, name, opts \\ []) do
    {igniter, timestamp} = next_migration_timestamp(igniter)
    Igniter.Libs.Ecto.gen_migration(igniter, repo, name, Keyword.put(opts, :timestamp, timestamp))
  end

  defp next_migration_timestamp(igniter) do
    igniter = Igniter.include_glob(igniter, "priv/*/migrations/**/*.exs")

    last_used = igniter.assigns[:composer_last_migration_timestamp] || 0

    timestamp =
      Enum.max([migration_timestamp(), last_used + 1, highest_migration_version(igniter) + 1])

    igniter = Igniter.assign(igniter, :composer_last_migration_timestamp, timestamp)

    {igniter, timestamp}
  end

  # Our own counter only knows about migrations we generated. A package's
  # installer composes into the same run now rather than a separate
  # subprocess seconds later, so its migration can share our second — read
  # the versions actually present instead of assuming.
  defp highest_migration_version(igniter) do
    igniter.rewrite
    |> Rewrite.paths()
    |> Enum.filter(&String.match?(&1, ~r{priv/[^/]+/migrations/}))
    |> Enum.map(fn path ->
      case path |> Path.basename() |> Integer.parse() do
        {version, _rest} -> version
        :error -> 0
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp migration_timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    String.to_integer("#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}")
  end

  defp pad(i) when i < 10, do: "0#{i}"
  defp pad(i), do: "#{i}"
end
