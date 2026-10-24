# This is composer's built-in cookbook, `cb_std`. It is laid out exactly like
# any package's cookbook (lib/composer/cb_std/{steps,recipes}), and
# its steps are referenced as "cb_std:<id>", e.g. "cb_std:setup/credo".
#
# `cb_std` is the one exception to the rule that a cookbook is named after its
# package's OTP app (:composer). The name is reserved, so no other package
# can define it.
defmodule Composer.CbStd do
  @moduledoc """
  Composer's built-in cookbook: steps for setting up a fresh `phx.new` app.

  List them with `mix composer.step.list --cookbook cb_std`.
  """

  use Composer.Cookbook,
    summary: "Composer's built-in steps for Phoenix apps",
    homepage: "https://github.com/elixir-composer/composer"
end
