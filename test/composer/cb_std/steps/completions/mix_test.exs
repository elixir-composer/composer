defmodule Composer.CbStd.Steps.Completions.MixTest do
  use ExUnit.Case, async: true

  alias Composer.CbStd.Steps.Completions

  # The step shells out to `mix`, so only its metadata is tested here.
  test "is experimental" do
    meta = Completions.Mix.__composer_step__()

    assert meta.stability == :experimental
    assert meta.action == :gen
  end
end
