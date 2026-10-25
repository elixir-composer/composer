defmodule Composer.PreflightTest do
  use ExUnit.Case, async: true

  alias Composer.Preflight

  defp entry(requires) do
    %{label: "x:step", meta: %Composer.Step.Meta{requires: requires}}
  end

  test "a missing executable is an error" do
    assert {:error, {:requires_unmet, [failure]}} =
             Preflight.check([entry([{:executable, "nope"}])], find_executable: fn _ -> nil end)

    assert failure =~ ~s(x:step: requires the executable "nope")
    assert :ok = Preflight.check([entry([{:executable, "sh"}])], find_executable: &"/bin/#{&1}")
  end

  test "an incompatible version of a present package is an error; an absent one passes" do
    versions = %{phoenix: "1.7.14"}
    opts = [package_version: &versions[&1]]

    assert {:error, {:requires_unmet, [failure]}} =
             Preflight.check([entry([{:package, :phoenix, "~> 1.8"}])], opts)

    assert failure =~ "requires phoenix ~> 1.8, but this app has phoenix 1.7.14"
    assert :ok = Preflight.check([entry([{:package, :phoenix, "~> 1.7"}])], opts)
    assert :ok = Preflight.check([entry([{:package, :ash, "~> 3.0"}])], opts)
  end

  test "step requirements and entries without metadata are not checked here" do
    assert :ok = Preflight.check([entry(["cb_std:setup:credo"]), %{label: "hex:oban", meta: nil}])
  end

  test "requires: [\"hex:pkg\"] passes alongside a sourced install of the package" do
    install = %{
      ref: "hex:my_lib",
      label: "hex:my_lib (path ../my_lib)",
      step: {:install, :my_lib, [source: [path: "../my_lib"]]},
      meta: nil
    }

    assert :ok = Preflight.check([install, entry(["hex:my_lib"])])
  end
end
