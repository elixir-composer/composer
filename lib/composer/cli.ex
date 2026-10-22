defmodule Composer.CLI do
  @moduledoc false
  # Helpers shared by the mix composer.* tasks: option parsing, discovery,
  # raising on errors, and rendering text and JSON.

  alias Composer.{Discovery, Error, Resolver}

  @config_switches [config: :string, json: :boolean]
  @config_aliases [c: :config]

  # Options of mix composer.recipe.run and Igniter's global switches that
  # take a value; every other --switch is a boolean.
  @value_switches ["--config", "-c", "--scribe", "--only"]

  @doc "Parses argv strictly with `-c/--config`, `--json` and `extra` switches."
  def parse!(argv, extra \\ []) do
    OptionParser.parse!(argv, strict: @config_switches ++ extra, aliases: @config_aliases)
  end

  @doc """
  Pre-scans argv for `--config` and the positional arguments without knowing
  the recipe's flags yet. `OptionParser` would take a positional following
  an unknown `--flag` as that flag's value.
  """
  def prescan(argv), do: prescan(argv, nil, [])

  defp prescan([], config, positional), do: {config, Enum.reverse(positional)}
  defp prescan(["--" | _rest], config, positional), do: {config, Enum.reverse(positional)}

  defp prescan([switch, value | rest], config, positional) when switch in @value_switches do
    config = if switch in ["--config", "-c"], do: value, else: config
    prescan(rest, config, positional)
  end

  defp prescan(["--config=" <> value | rest], _config, positional),
    do: prescan(rest, value, positional)

  defp prescan(["-" <> _ | rest], config, positional), do: prescan(rest, config, positional)
  defp prescan([arg | rest], config, positional), do: prescan(rest, config, [arg | positional])

  @doc """
  Raises `{:unknown_flag, ...}` for the first `--switch` in `argv` that is
  not in `schema`, `aliases` or Igniter's global options. `root` and
  `declared` (the recipe's flags) word the message.
  """
  def check_switches!(argv, schema, aliases, root, declared) do
    {own, _passthrough} = split_passthrough(argv)
    strict = schema ++ Igniter.Mix.Task.Info.global_options()[:switches]

    case OptionParser.parse(own, strict: strict, aliases: aliases) do
      {_opts, _args, []} ->
        :ok

      {_opts, _args, [{switch, _value} | _]} ->
        Mix.raise(Error.message({:unknown_flag, switch, root, declared}))
    end
  end

  @doc "Splits argv at `--` into `{own, passthrough}`."
  def split_passthrough(argv) do
    case Enum.split_while(argv, &(&1 != "--")) do
      {own, ["--" | passthrough]} -> {own, passthrough}
      {own, []} -> {own, []}
    end
  end

  @doc """
  Discovers the cookbooks, raising on error.

  Dependencies are compiled first, so their cookbooks are loaded. The
  result is memoized per process, so `info/2` and `igniter/1` of one task
  run discover once, and the completion index is refreshed as a side effect.
  """
  def cookbooks!(config \\ nil) do
    opts = Keyword.merge(Application.get_env(:composer, :discovery, []), config: config)
    key = {__MODULE__, :cookbooks, opts}

    case Process.get(key) do
      nil ->
        compile()
        cookbooks = ok!(Discovery.cookbooks(opts))
        Composer.Index.refresh(cookbooks)
        Process.put(key, cookbooks)
        cookbooks

      cookbooks ->
        cookbooks
    end
  end

  @doc """
  The cookbook an unqualified command-line reference is looked up in first:
  the current project's own.
  """
  def context(cookbooks) do
    case Discovery.own(cookbooks) do
      nil -> nil
      cookbook -> cookbook.name
    end
  end

  @doc "Raises unless running inside a Mix project."
  def require_project! do
    unless Mix.Project.get(), do: Mix.raise(Error.message(:not_in_project))
  end

  defp compile do
    if Mix.Project.get(), do: Mix.Task.run("compile", [])
  end

  @doc """
  Runs `fun` with a quiet Mix shell (when `quiet?`), so that compiling and
  loading dependencies print nothing on stdout; the shell is restored
  afterwards, even on a raise.
  """
  def quietly(quiet? \\ true, fun)
  def quietly(false, fun), do: fun.()

  def quietly(true, fun) do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)

    try do
      fun.()
    after
      Mix.shell(shell)
    end
  end

  @doc "Unwraps `{:ok, value}` or raises `Mix.Error` with the formatted reason."
  def ok!({:ok, value}), do: value
  def ok!(:ok), do: :ok
  def ok!({:error, reason}), do: Mix.raise(Error.message(reason))

  @doc "Prints `data` as pretty JSON."
  def json(data), do: Mix.shell().info(Jason.encode!(data, pretty: true))

  @doc "Renders rows of strings as left-aligned columns."
  def table([]), do: ""

  def table(rows) do
    widths =
      rows
      |> Enum.map(fn row -> Enum.map(row, &String.length/1) end)
      |> Enum.zip_with(&Enum.max/1)

    Enum.map_join(rows, "\n", fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
      |> String.trim_trailing()
      |> then(&("  " <> &1))
    end)
  end

  @doc """
  Renders numbered entries: `   4. core:setup/credo  [local:tooling] if :dev`.

  With `aliases: true`, a step referenced through a cookbook alias is
  followed by the alias: `cc_lab:auth/passkeys (as lab)`.
  """
  def render_entries(entries, opts \\ []) do
    width = entries |> length() |> Integer.to_string() |> String.length()

    entries
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {entry, n} ->
      number = n |> Integer.to_string() |> String.pad_leading(width)
      "  #{number}. " <> render_entry(entry, opts)
    end)
  end

  @doc "Renders one entry without a number; options as for `render_entries/2`."
  def render_entry(entry, opts \\ []) do
    shown = if opts[:aliases], do: shown_alias(Map.get(entry, :alias)), else: ""

    [entry.label, shown, flag(entry.if), origin(entry.origin), gates(entry.gates)]
    |> IO.iodata_to_binary()
  end

  defp shown_alias(nil), do: ""
  defp shown_alias(name), do: " (as #{name})"

  @doc "Returns an entry as JSON-ready data."
  def entry_data(entry) do
    %{
      "ref" => entry.ref,
      "label" => entry.label,
      "origin" => entry.origin,
      "if" => entry.if && Atom.to_string(entry.if),
      "alias" => Map.get(entry, :alias),
      "gates" => Enum.map(entry.gates, &Atom.to_string/1)
    }
  end

  @doc "Prints resolver warnings, if any."
  def print_warnings([]), do: :ok

  def print_warnings(warnings) do
    Mix.shell().info("\nWarnings:")
    Enum.each(warnings, &Mix.shell().info([:yellow, "  * ", Error.warning(&1), :reset]))
  end

  @doc "Formats flags as `--flag-name` switches."
  def switches(flags), do: Enum.map_join(flags, " ", &switch/1)
  def switch(flag), do: "--" <> String.replace(Atom.to_string(flag), "_", "-")

  @doc "Resolves a recipe from the command line, raising on error."
  def resolve_recipe!(cookbooks, ref, flags \\ :all) do
    ok!(Resolver.resolve_recipe(cookbooks, ref, flags: flags, context: context(cookbooks)))
  end

  defp flag(nil), do: ""
  defp flag(flag), do: ", if: #{inspect(flag)}"

  defp origin(nil), do: ""
  defp origin(origin), do: "  [#{origin}]"

  defp gates([]), do: ""
  defp gates(gates), do: " if " <> Enum.map_join(gates, " and ", &inspect/1)
end
