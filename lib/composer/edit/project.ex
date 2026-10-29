defmodule Composer.Edit.Project do
  @moduledoc """
  Names in the target app, for steps.
  """

  @doc "Returns the camelized app module name (e.g. `\"MyApp\"`)."
  def app_module(igniter) do
    Igniter.Project.Application.app_name(igniter) |> to_string() |> Macro.camelize()
  end

  @doc "Returns the app's Repo module (e.g. `MyApp.Repo`)."
  def repo(igniter) do
    Module.concat([app_module(igniter), "Repo"])
  end

  @doc "Returns the app's web module name (e.g. `\"MyAppWeb\"`)."
  def app_web_module(igniter) do
    app_module(igniter) <> "Web"
  end
end
