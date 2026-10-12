defmodule Mix.Tasks.Composer.Install do
  @shortdoc "Installs composer"

  @moduledoc """
  Installs composer. Invoked by igniter via `mix igniter.install composer`.
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :composer,
      schema: [],
      aliases: []
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Igniter.add_notice(igniter, "composer is installed")
  end
end
