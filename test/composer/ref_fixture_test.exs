defmodule Composer.RefFixtureTest do
  use ExUnit.Case, async: true

  alias Composer.Ref

  # The fixture is shared with the composer_new archive's ComposerNew.Ref,
  # a copy of these rules (the archive can't depend on composer).
  {fixture, _binding} = Code.eval_file(Path.expand("installer/test/fixtures/refs.exs"))
  @fixture fixture

  # The archive splits REF on its first @: the name is a reference here, and
  # the spec is the source of hex:<cookbook>@<spec>.
  defp parse(string) do
    case String.split(String.trim(string), "@", parts: 2) do
      [name] ->
        with {:ok, ref} <- Ref.parse(name), do: {:ok, ref.cookbook, ref.path, []}

      [name, spec] ->
        with {:ok, ref} <- Ref.parse(name),
             {:ok, hex} <- Ref.parse("hex:" <> (ref.cookbook || "") <> "@" <> spec),
             do: {:ok, ref.cookbook, ref.path, hex.source}
    end
  end

  test "Composer.Ref agrees with ComposerNew.Ref on the shared fixture" do
    for {string, expected} <- @fixture do
      case {expected, parse(string)} do
        {:error, {:error, {:invalid_ref, _, _}}} -> :ok
        {same, same} -> :ok
        {expected, got} -> flunk("#{string}: expected #{inspect(expected)}, got #{inspect(got)}")
      end
    end
  end
end
