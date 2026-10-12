defmodule Composer.Core.Steps.GeneratorDefaultsTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "repo_config" do
    test "configures generators and migration timestamps" do
      igniter = Igniter.compose_task(test_project(), Composer.Core.Steps.Setup.GeneratorDefaults)

      config_diff = diff(igniter, only: "config/config.exs")
      assert config_diff =~ "timestamp_type: :utc_datetime_usec"
      assert config_diff =~ "binary_id: true"
      assert config_diff =~ "migration_timestamps"
    end
  end
end
