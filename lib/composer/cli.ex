defmodule Composer.CLI do
  @moduledoc false
  # Helpers shared by the mix composer.* tasks: option parsing, discovery,
  # raising on errors, and rendering text and JSON.

  alias Composer.{Discovery, Error, Resolver}

  @switches [json: :boolean]

  # Options of mix composer.recipe.run and Igniter's global switches that
  # take a value; every other --switch is a boolean.
  @value_switches ["--scribe", "--only"]

  @doc "Parses argv strictly with `--json` and `extra` switches."
  def parse!(argv, extra \\ []) do
    OptionParser.parse!(argv, strict: @switches ++ extra)
  end

  @doc """
  Pre-scans argv for the positional arguments without knowing the recipe's
  flags yet. `OptionParser` would take a positional following an unknown
  `--flag` as that flag's value.
  """
  def prescan(argv), do: prescan(argv, [])

  defp prescan([], positional), do: Enum.reverse(positional)
  defp prescan(["--" | _rest], positional), do: Enum.reverse(positional)

  defp prescan([switch, _value | rest], positional) when switch in @value_switches,
    do: prescan(rest, positional)

  defp prescan(["-" <> _ | rest], positional), do: prescan(rest, positional)
  defp prescan([arg | rest], positional), do: prescan(rest, [arg | positional])

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

  With `quiet: true` (for `--json`), compiling prints nothing on stdout, so
  the output parses even when the build was stale. Compile errors still
  raise. With `refresh: true`, the project is compiled again and the
  cookbooks rediscovered, after a task has rewritten its source.
  """
  def cookbooks!(opts \\ []) do
    discovery = Application.get_env(:composer, :discovery, [])
    key = {__MODULE__, :cookbooks, discovery}

    if opts[:refresh] do
      Process.delete(key)
      for task <- ~w(compile compile.all compile.elixir), do: Mix.Task.reenable(task)
    end

    case Process.get(key) do
      nil ->
        quietly(opts[:quiet] || false, &compile/0)
        cookbooks = ok!(Discovery.cookbooks(discovery))
        Composer.Index.refresh(cookbooks)
        Process.put(key, cookbooks)
        cookbooks

      cookbooks ->
        cookbooks
    end
  end

  @doc """
  The resolution context of a command-line address (see
  `Composer.Resolver`): the current project's own cookbook, if it is one,
  no chapter, and CLI mode, where a bare name is searched.
  """
  def context(cookbooks) do
    own =
      case Discovery.own(cookbooks) do
        nil -> nil
        cookbook -> cookbook.name
      end

    %{cookbook: own, chapter: nil, cli?: true}
  end

  @doc """
  Prints `task`'s `mix help` page. A task given none of its required
  arguments shows this rather than raising a usage error.
  """
  def help(task), do: Mix.Task.rerun("help", [task])

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

  @doc """
  Prints `data` as pretty JSON, straight to stdout rather than through the
  Mix shell, which `MIX_QUIET=1` silences.
  """
  def json(data), do: IO.puts(Jason.encode!(data, pretty: true))

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
  Renders numbered entries: `   4. cb_std:setup:credo  [cb_lab/dev/tooling] if :dev`.

  With `aliases: true`, a step addressed through a cookbook alias is
  followed by the alias: `cc_lab:auth:passkeys (as lab)`.
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
