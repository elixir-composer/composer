defmodule Composer.CbStd.Steps.MixEnvConfigTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "env_config" do
    test "adds env: Mix.env() to config.exs" do
      igniter = Igniter.compose_task(test_project(), Composer.CbStd.Steps.Setup.MixEnvConfig)

      assert diff(igniter, only: "config/config.exs") =~ "env: Mix.env()"
    end
  end
end
