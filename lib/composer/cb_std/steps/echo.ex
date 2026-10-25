defmodule Composer.CbStd.Steps.Echo do
  @moduledoc """
  Prints a message to stdout when the step runs, and changes nothing. Use it
  while developing a recipe to see where a run has got to.

      mix composer.step.run cb_std:echo -- Hello from composer

  In a recipe, pass the message with `argv:`:

      steps: [
        {"cb_std:echo", argv: ["Before credo"]},
        "cb_std:setup:credo"
      ]

  The words of the message are joined with spaces, so
  `argv: ["Before", "credo"]` prints the same as `argv: ["Before credo"]`.
  The message is printed while the step composes, before any changes are
  shown or applied.
  """
  use Composer.Step,
    summary: "Prints a message to stdout",
    action: :debug,
    capability: [:devtools],
    stability: :stable

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{positional: [message: [rest: true, optional: true]]}
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    igniter.args.positional
    |> Map.get(:message, [])
    |> Enum.join(" ")
    |> Mix.shell().info()

    igniter
  end
end
