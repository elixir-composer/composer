# A fixture cookbook, compiled into composer's test build. The app: option
# stands in for a real :fake_book package.
defmodule Composer.FakeBook do
  @moduledoc false
  use Composer.Cookbook,
    app: :fake_book,
    summary: "A fixture cookbook",
    homepage: "https://example.com/fake_book"
end
