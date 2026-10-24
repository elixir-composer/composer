defmodule Composer.InstallerVersionTest do
  use ExUnit.Case, async: true

  # composer and the composer_new archive (installer/) are released in
  # lockstep: git_ops bumps both (managed_files in config/config.exs).
  # To split versions, see the checklist in installer/mix.exs.
  defp version(path) do
    [_, version] = Regex.run(~r/@version "([^"]+)"/, File.read!(path))
    version
  end

  test "composer and composer_new have the same version" do
    assert version("installer/mix.exs") == version("mix.exs")
  end
end
