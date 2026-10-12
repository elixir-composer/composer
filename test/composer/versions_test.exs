defmodule Composer.VersionsTest do
  use ExUnit.Case, async: true

  test "requirement/1 keeps three segments for 0.x, minor series otherwise" do
    assert Composer.Versions.requirement("0.3.1") == "~> 0.3.1"
    assert Composer.Versions.requirement("0.10.2") == "~> 0.10.2"
    assert Composer.Versions.requirement("1.0.0") == "~> 1.0"
    assert Composer.Versions.requirement("2.19.4") == "~> 2.19"
    assert Composer.Versions.requirement("1.8.0-rc.1") == "~> 1.8.0-rc.1"
  end

  test "fetch_npm_versions never raises and maps failures to nil" do
    # fetch_versions is disabled in tests, so every lookup returns nil
    assert Composer.Versions.fetch_npm_versions(["tailwindcss", "bun"]) ==
             %{"tailwindcss" => nil, "bun" => nil}
  end

  test "oban_pro version lookup degrades to nil offline" do
    assert Composer.Versions.fetch_oban_pro_version() == nil
  end
end
