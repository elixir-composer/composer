defmodule Composer.NoComposerNewTest do
  use ExUnit.Case, async: true

  # mix composer.new lives in the composer_new archive (installer/), never in
  # composer itself. Mix.Task.get/1 can't tell: on a machine with the archive
  # installed it finds the task anyway.
  test "composer does not ship Mix.Tasks.Composer.New" do
    refute Mix.Tasks.Composer.New in Application.spec(:composer, :modules)
  end
end
