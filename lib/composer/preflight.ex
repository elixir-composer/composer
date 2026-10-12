defmodule Composer.Preflight do
  @moduledoc """
  Checks the `requires` of the steps about to run, before anything runs.

    * `{:executable, name}` must be found on `PATH`.
    * `{:package, name, requirement}` must match the version of `name` when
      the target app already has that package; a package the app doesn't
      have yet passes, since an earlier step may install it.

  Both are errors. A required *step* that is not listed earlier is only a
  warning, reported by `Composer.Resolver.warnings/1`.
  """

  @doc """
  Checks `entries`, returning `:ok` or `{:error, {:requires_unmet, failures}}`
  where each failure is a message line.

  ## Options

    * `:find_executable` - `(name -> path | nil)`, for tests
    * `:package_version` - `(name -> version | nil)`, for tests
  """
  @spec check([Composer.Resolver.entry()], keyword()) :: :ok | {:error, term()}
  def check(entries, opts \\ []) do
    find_executable = Keyword.get(opts, :find_executable, &System.find_executable/1)
    package_version = Keyword.get(opts, :package_version, &package_version/1)

    failures =
      for %{meta: %{requires: requires}} = entry <- entries,
          requirement <- requires,
          failure = failure(requirement, find_executable, package_version),
          do: "#{entry.label}: #{failure}"

    case Enum.uniq(failures) do
      [] -> :ok
      failures -> {:error, {:requires_unmet, failures}}
    end
  end

  defp failure({:executable, name}, find_executable, _package_version) do
    unless find_executable.(name) do
      "requires the executable #{inspect(name)}, which is not on your PATH. Install it and try again."
    end
  end

  defp failure({:package, name, requirement}, _find_executable, package_version) do
    with version when is_binary(version) <- package_version.(name),
         {:ok, parsed} <- Version.parse(version),
         false <- Version.match?(parsed, requirement, allow_pre: true) do
      "requires #{name} #{requirement}, but this app has #{name} #{version}. " <>
        "Update the dependency (mix deps.update #{name}) or pick a compatible step."
    else
      _ -> nil
    end
  end

  defp failure(_step_ref, _find_executable, _package_version), do: nil

  # The version of a package the target app already depends on, read from
  # its compiled .app. nil when it isn't a dependency (yet).
  defp package_version(name) do
    if Mix.Project.get() && Map.has_key?(Mix.Project.deps_paths(), name) do
      Application.load(name)

      case Application.spec(name, :vsn) do
        nil -> nil
        vsn -> to_string(vsn)
      end
    end
  end
end
