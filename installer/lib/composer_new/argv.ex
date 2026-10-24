defmodule ComposerNew.Argv do
  @moduledoc """
  Splits `mix composer.new` argv into APP, REF, the archive's own options
  and the recipe flags.

  This is a manual pass, like `igniter.new`'s, rather than `OptionParser`
  in `:strict` mode: a strict parse drops the switches it doesn't know,
  which are the recipe flags here, and would read the `--no-ecto` of
  `--with-args --no-ecto` as a switch. The rules:

    * APP is the first argument
    * an option with a value takes `--opt=value` or `--opt value`; for
      `--with-args`, the separate form takes the next argument as it is,
      even when it starts with `-`
    * `--install` and `--extra-dep` repeat, and `--install` also splits
      on `,`
    * `--reset`, `--dry-run` and `--no-recipe` are booleans
    * any other `-x` or `--x` is a recipe flag, kept in order
    * after `--`, everything is a recipe flag
    * the second positional argument is REF, and a third is an error
  """

  @valued %{
    "--with" => :with,
    "--with-args" => :with_args,
    "--install" => :install,
    "--composer" => :composer,
    "--extra-dep" => :extra_dep,
    "--igniter-local" => :igniter_local
  }

  @booleans %{"--reset" => :reset, "--dry-run" => :dry_run, "--no-recipe" => :no_recipe}

  @repeated [:install, :extra_dep]

  @defaults [
    with: nil,
    with_args: nil,
    install: [],
    composer: nil,
    extra_dep: [],
    igniter_local: nil,
    reset: false,
    dry_run: false,
    no_recipe: false
  ]

  @type t :: %{
          app: String.t(),
          ref: String.t() | nil,
          opts: keyword(),
          recipe_flags: [String.t()]
        }

  @doc "Parses argv."
  @spec parse([String.t()]) :: {:ok, t()} | {:error, String.t()}
  def parse([]), do: {:error, "Give the app name first: mix composer.new APP [REF] [OPTIONS]"}

  def parse(["-" <> _ = first | _rest]) do
    {:error,
     "The first argument must be the app name, got: #{first}. " <>
       "Usage: mix composer.new APP [REF] [OPTIONS]"}
  end

  def parse([app | rest]) do
    acc = %{app: app, ref: nil, opts: @defaults, recipe_flags: []}

    with {:ok, acc} <- walk(rest, acc) do
      {:ok, %{acc | recipe_flags: Enum.reverse(acc.recipe_flags)}}
    end
  end

  defp walk([], acc), do: {:ok, acc}

  defp walk(["--" | rest], acc),
    do: {:ok, %{acc | recipe_flags: Enum.reverse(rest, acc.recipe_flags)}}

  defp walk(["-" <> _ = arg | rest], acc) do
    {switch, inline} =
      case String.split(arg, "=", parts: 2) do
        [switch] -> {switch, nil}
        [switch, value] -> {switch, value}
      end

    cond do
      key = @valued[switch] ->
        valued(key, switch, inline, rest, acc)

      key = @booleans[arg] ->
        walk(rest, put(acc, key, true))

      true ->
        walk(rest, %{acc | recipe_flags: [arg | acc.recipe_flags]})
    end
  end

  defp walk([positional | rest], %{ref: nil} = acc), do: walk(rest, %{acc | ref: positional})

  defp walk([positional | _rest], acc) do
    {:error,
     "Unexpected argument #{inspect(positional)}: mix composer.new takes APP and one REF " <>
       "(got #{inspect(acc.app)} and #{inspect(acc.ref)})"}
  end

  defp valued(key, _switch, value, rest, acc) when is_binary(value),
    do: walk(rest, put(acc, key, value))

  defp valued(:with_args, _switch, nil, [value | rest], acc),
    do: walk(rest, put(acc, :with_args, value))

  defp valued(key, switch, nil, [value | rest], acc) do
    if String.starts_with?(value, "-"),
      do: missing(switch),
      else: walk(rest, put(acc, key, value))
  end

  defp valued(_key, switch, nil, [], _acc), do: missing(switch)

  defp missing(switch), do: {:error, "#{switch} needs a value"}

  defp put(acc, :install, value) do
    packages = String.split(value, ",", trim: true)
    %{acc | opts: Keyword.update!(acc.opts, :install, &(&1 ++ packages))}
  end

  defp put(acc, key, value) when key in @repeated,
    do: %{acc | opts: Keyword.update!(acc.opts, key, &(&1 ++ [value]))}

  defp put(acc, key, value), do: %{acc | opts: Keyword.put(acc.opts, key, value)}
end
