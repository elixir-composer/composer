defmodule Composer.Local do
  @moduledoc """
  Local: your recipes, outside any project.

      ~/.config/composer/
        recipes/ash.exs       # local:ash/base, local:ash/auth, ...
        recipes/lv.exs        # local:lv/base, ...

  Local holds recipe groups only (see `Composer.Recipe.Group`). Its
  recipes reference steps from package cookbooks (`"core:setup/credo"`) and
  other recipes (`{:use, "local:ash/base"}`, or `{:use, "base"}` within
  the same group). Personal steps, and the templates beside them, belong in
  a small cookbook package added as a path dependency.

  A `steps/` or `templates/` directory here is an error. Any other entry
  besides `recipes/` is left alone (so a later composer can add settings
  files), and `mix composer.cookbook.lint --local` reports it. Entries
  starting with `.` are ignored.

  The directory is found in this order, first match wins:

    1. the `-c` / `--config` option of a composer task
    2. the `COMPOSER_CONFIG` environment variable
    3. `$XDG_CONFIG_HOME/composer`
    4. `~/.config/composer`

  A directory given by 1 or 2 must exist. The default directories may be
  missing, which just means you have no local recipes.

  > #### Warning {: .warning}
  >
  > Group files are Elixir code, evaluated with `Code.eval_file/1`. Only
  > use recipes you wrote or trust.
  """

  alias Composer.Cookbook

  @doc """
  Returns the config directory and whether it was given explicitly.
  """
  @spec dir(String.t() | nil) :: {Path.t(), :explicit | :default}
  def dir(config \\ nil)
  def dir(config) when is_binary(config) and config != "", do: {Path.expand(config), :explicit}

  def dir(_config) do
    cond do
      env = present(System.get_env("COMPOSER_CONFIG")) ->
        {Path.expand(env), :explicit}

      xdg = present(System.get_env("XDG_CONFIG_HOME")) ->
        {Path.join(Path.expand(xdg), "composer"), :default}

      true ->
        {Path.expand("~/.config/composer"), :default}
    end
  end

  # Entries that hold code or files only a package cookbook can hold.
  @recipes_only ["steps", "templates"]

  @doc """
  Builds the `local` cookbook from the config directory.
  """
  @spec cookbook(String.t() | nil) :: {:ok, Cookbook.t()} | {:error, term()}
  def cookbook(config \\ nil) do
    {dir, how} = dir(config)

    cond do
      File.dir?(dir) ->
        case Enum.find(entries(dir), &(&1 in @recipes_only)) do
          nil -> {:ok, build(dir)}
          entry -> {:error, {:local_recipes_only, dir, entry}}
        end

      File.exists?(dir) ->
        {:error, {:config_dir_not_dir, dir}}

      how == :explicit ->
        {:error, {:config_dir_missing, dir}}

      true ->
        {:ok, build(dir)}
    end
  end

  @doc """
  Returns the top-level entries of the config directory other than
  `recipes/`, sorted. Entries starting with `.` are left out.
  """
  @spec entries(Path.t()) :: [String.t()]
  def entries(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 == "recipes" or String.starts_with?(&1, ".")))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc "True for an entry that local rejects outright (`steps`, `templates`)."
  @spec recipes_only?(String.t()) :: boolean()
  def recipes_only?(entry), do: entry in @recipes_only

  @doc false
  # The local cookbook for `dir`, without checking it (lint inspects it).
  def build(dir) do
    %Cookbook{
      name: "local",
      kind: :local,
      summary: "Your recipes in #{dir}",
      source_dir: dir
    }
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
