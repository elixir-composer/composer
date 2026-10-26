defmodule ComposerNew.Argv do
  @moduledoc """
  Splits `mix composer.new` argv into APP and the archive's options.

  This is a manual pass, like `igniter.new`'s, rather than `OptionParser`
  in `:strict` mode: a strict parse would read the `--no-ecto` of
  `--with-args --no-ecto` as a switch. The rules:

    * APP is the first argument, and the only positional one
    * an option with a value takes `--opt=value` or `--opt value`; for
      `--with-args` and `--recipe-args`, the separate form takes the next
      argument as it is, even when it starts with `-`
    * `--install` and `--cookbook` repeat, and `--install` also splits on
      `,`; any other option may be given once
    * `--reset` and `--dry-run` are booleans
    * any other switch is an error: recipe flags go in `--recipe-args`
    * `--recipe-args` needs `--recipe`
  """

  @valued %{
    "--with" => :with,
    "--with-args" => :with_args,
    "--install" => :install,
    "--composer" => :composer,
    "--cookbook" => :cookbook,
    "--recipe" => :recipe,
    "--recipe-args" => :recipe_args,
    "--igniter-local" => :igniter_local
  }

  @booleans %{"--reset" => :reset, "--dry-run" => :dry_run}

  # Options whose separate form takes the next argument even if it starts with -.
  @verbatim [:with_args, :recipe_args]

  @repeated [:install, :cookbook]

  @defaults [
    with: nil,
    with_args: nil,
    install: [],
    composer: nil,
    cookbook: [],
    recipe: nil,
    recipe_args: nil,
    igniter_local: nil,
    reset: false,
    dry_run: false
  ]

  @usage "mix composer.new APP [--cookbook PKG] [--recipe REF [--recipe-args ARGS]] [OPTIONS]"

  @type t :: %{app: String.t(), opts: keyword()}

  @doc "Parses argv."
  @spec parse([String.t()]) :: {:ok, t()} | {:error, String.t()}
  def parse([]), do: {:error, "Give the app name first: #{@usage}"}

  def parse(["-" <> _ = first | _rest]) do
    {:error, "The first argument must be the app name, got: #{first}. Usage: #{@usage}"}
  end

  def parse([app | rest]) do
    with {:ok, acc} <- walk(rest, %{app: app, opts: @defaults, given: MapSet.new()}),
         :ok <- recipe_args(acc.opts),
         do: {:ok, Map.take(acc, [:app, :opts])}
  end

  @doc """
  True when argv asks for help: a `--help` or `-h` that isn't the value of
  `--with-args` or `--recipe-args`.
  """
  @spec help?([String.t()]) :: boolean()
  def help?([]), do: false

  def help?([switch, _value | rest]) when switch in ["--with-args", "--recipe-args"],
    do: help?(rest)

  def help?([arg | _rest]) when arg in ["--help", "-h"], do: true
  def help?([_arg | rest]), do: help?(rest)

  defp walk([], acc), do: {:ok, acc}

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
        {:error,
         "Unknown option #{arg}. Recipe flags go in --recipe-args, " <>
           ~s(as in --recipe-args="#{arg}")}
    end
  end

  defp walk([positional | _rest], acc) do
    hint =
      if String.contains?(positional, "/"),
        do: "; name the recipe with --recipe #{positional}",
        else: ""

    {:error,
     "Unexpected argument #{inspect(positional)}: mix composer.new takes only APP " <>
       "(got #{inspect(acc.app)})" <> hint}
  end

  defp valued(key, switch, value, rest, acc) do
    cond do
      key not in @repeated and MapSet.member?(acc.given, key) ->
        {:error, "#{switch} may be given only once"}

      is_binary(value) ->
        walk(rest, put(acc, key, value))

      rest == [] ->
        missing(switch)

      key in @verbatim ->
        walk(tl(rest), put(acc, key, hd(rest)))

      String.starts_with?(hd(rest), "-") ->
        missing(switch)

      true ->
        walk(tl(rest), put(acc, key, hd(rest)))
    end
  end

  defp missing(switch), do: {:error, "#{switch} needs a value"}

  defp recipe_args(opts) do
    if opts[:recipe_args] && !opts[:recipe],
      do: {:error, "--recipe-args needs --recipe: the arguments are the recipe's flags"},
      else: :ok
  end

  defp put(acc, :install, value) do
    packages = String.split(value, ",", trim: true)
    %{acc | opts: Keyword.update!(acc.opts, :install, &(&1 ++ packages))}
  end

  defp put(acc, key, value) when key in @repeated,
    do: %{acc | opts: Keyword.update!(acc.opts, key, &(&1 ++ [value]))}

  defp put(acc, key, value),
    do: %{acc | opts: Keyword.put(acc.opts, key, value), given: MapSet.put(acc.given, key)}
end
