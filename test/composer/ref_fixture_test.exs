defmodule Composer.RefFixtureTest do
  use ExUnit.Case, async: true

  alias Composer.Ref

  # The fixture is shared with the composer_new archive's ComposerNew.Ref,
  # a copy of this grammar (the archive can't depend on composer).
  {fixture, _binding} = Code.eval_file(Path.expand("installer/test/fixtures/refs.exs"))
  @fixture fixture

  @fields [:kind, :scope, :cookbook, :up, :segments, :source]

  test "Composer.Ref agrees with ComposerNew.Ref on the shared fixture" do
    for entry <- @fixture do
      {string, expected} =
        case entry do
          {string, _expected, :archive} -> {string, :error}
          {string, expected, :composer} -> {string, expected}
          {string, expected} -> {string, expected}
        end

      case {expected, Ref.parse(string)} do
        {:error, {:error, {:invalid_ref, ^string, _why}}} ->
          :ok

        {{:ok, fields}, {:ok, ref}} ->
          assert Map.take(ref, @fields) == fields, "#{inspect(string)} parsed as #{inspect(ref)}"

        {expected, got} ->
          flunk("#{inspect(string)}: expected #{inspect(expected)}, got #{inspect(got)}")
      end
    end
  end
end
