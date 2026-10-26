if Code.ensure_loaded?(Composer) do
  defmodule Composer.FakeFramework do
    @moduledoc false
    use Composer.Cookbook, summary: "A framework's bundled cookbook"
  end
end
