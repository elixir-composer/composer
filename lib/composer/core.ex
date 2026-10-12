# This is composer's built-in cookbook, `core`. It is laid out exactly like
# any package's cookbook (lib/composer/core/{steps,recipes}), and
# its steps are referenced as "core:<id>", e.g. "core:setup/credo".
#
# `core` is the one exception to the rule that a cookbook is named after its
# package's OTP app (:composer). The name is reserved, so no other package
# can define it.
defmodule Composer.Core do
  @moduledoc """
  Composer's built-in cookbook: steps for setting up a fresh `phx.new` app.

  List them with `mix composer.step.list --cookbook core`.
  """

  use Composer.Cookbook,
    summary: "Composer's built-in steps for Phoenix apps",
    homepage: "https://github.com/andyl/composer"
end
