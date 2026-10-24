defmodule Composer.Discovery do
  @moduledoc """
  Finds the cookbooks available to the current project.

  Discovery is a convention lookup, not a scan. For each dependency app (and
  the current project), composer checks whether `Composer.<App>` is loaded
  and defines a cookbook. A dependency that ships `lib/composer/<app>.ex` is
  found with no configuration.

  The cookbooks, in order:

    * `cb_std`, composer's built-in cookbook, always
    * the current project's own cookbook, if it defines one
    * every dependency's cookbook

  The virtual `hex` cookbook is not listed; `Composer.Resolver` knows it.

  ## Limiting cookbooks

  The host app can allow or deny package cookbooks by name. `cb_std` is
  always available.

      # config/config.exs
      config :composer, cookbooks: [except: [:some_cookbook]]
      config :composer, cookbooks: [only: [:cc_lab]]

  Dependencies must be compiled before discovery, which is why composer's
  tasks run `mix compile` first; an uncompiled dependency's cookbook is not
  loaded and so not found.
  """

  alias Composer.Cookbook

  @doc """
  Returns the available cookbooks.

  ## Options

    * `:apps` - the apps to look in, instead of the project and its deps
    * `:modules` - extra cookbook modules to include, for tests
    * `:cookbooks` - extra `Composer.Cookbook` structs to include, for tests
    * `:filter` - `[only: names, except: names]`, instead of the app config
  """
  @spec cookbooks(keyword()) :: {:ok, [Cookbook.t()]} | {:error, term()}
  def cookbooks(opts \\ []) do
    modules =
      opts
      |> Keyword.get_lazy(:apps, &project_apps/0)
      |> Enum.reject(&(&1 == :composer))
      |> Enum.map(&Cookbook.module_for(Atom.to_string(&1)))
      |> Kernel.++(Keyword.get(opts, :modules, []))
      |> Enum.uniq()
      |> Enum.filter(&Cookbook.cookbook_module?/1)

    code =
      Enum.map([Composer.CbStd | modules], &Cookbook.from_module/1) ++
        Keyword.get(opts, :cookbooks, [])

    with :ok <- check_duplicates(code) do
      filter =
        Keyword.get_lazy(opts, :filter, fn -> Application.get_env(:composer, :cookbooks) end)

      {:ok, apply_filter(code, filter)}
    end
  end

  @doc "The current project's own cookbook, if it defines one."
  @spec own([Cookbook.t()]) :: Cookbook.t() | nil
  def own(cookbooks) when is_list(cookbooks) do
    with true <- Mix.Project.get() != nil,
         app when is_atom(app) and app != nil <- Mix.Project.config()[:app] do
      name = if app == :composer, do: "cb_std", else: Atom.to_string(app)
      Enum.find(cookbooks, &(&1.name == name and &1.kind == :code))
    else
      _ -> nil
    end
  end

  defp project_apps do
    if Mix.Project.get() do
      own = List.wrap(Mix.Project.config()[:app])
      own ++ Map.keys(Mix.Project.deps_paths())
    else
      []
    end
  end

  # Each module name is one cookbook name, so duplicates mean a module that
  # reports a name other than its own, e.g. one defined in one app and
  # registered under another.
  defp check_duplicates(cookbooks) do
    cookbooks
    |> Enum.group_by(& &1.name)
    |> Enum.find(fn {_name, group} -> length(group) > 1 end)
    |> case do
      nil -> :ok
      {name, group} -> {:error, {:duplicate_cookbook, name, Enum.map(group, & &1.module)}}
    end
  end

  defp apply_filter(cookbooks, nil), do: cookbooks

  defp apply_filter(cookbooks, filter) when is_list(filter) do
    only = names(filter[:only])
    except = names(filter[:except]) || []

    Enum.filter(cookbooks, fn %{name: name} ->
      name == "cb_std" or ((only == nil or name in only) and name not in except)
    end)
  end

  defp names(nil), do: nil
  defp names(list), do: Enum.map(List.wrap(list), &to_string/1)
end
