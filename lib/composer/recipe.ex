defmodule Composer.Recipe do
  @moduledoc """
  A recipe: a named, self-describing list of steps. Recipes live in
  chapter files (see `Composer.Recipe.Chapter`), `recipes/<chapter>.exs`, and
  are addressed as `<cookbook>:<chapter>/<name>`.

      # recipes/ash.exs
      [
        base: [
          shortdoc: "Ash core: sourceror, ash and ash_phoenix",
          steps: ["cc_lab:sourceror", "cc_lab:ash", "cc_lab:ash/phoenix"]
        ],
        auth: [
          shortdoc: "Ash with authentication and accounts",
          doc: \"""
          Builds on ash/base. Pass --oban-pro to add Oban Pro.
          \""",
          flags: [oban_pro: "Add Oban Pro"],
          steps: [
            {:use, "base"},
            "cc_lab:ash/authentication",
            {"cb_std:oban_pro", if: :oban_pro},
            {:task, "ash.codegen", ["initial"]},
            {:queue, "ecto.setup", []}
          ]
        ]
      ]

  ## Keys

    * `shortdoc` (required) - one line, shown by `mix composer.recipe.list`
    * `doc` - longer help, shown by `mix composer.recipe.show`
    * `flags` - `[flag: "description"]`. Every `if: :flag` in the recipe's
      own steps must be declared here, and `mix composer.recipe.run`
      rejects a `--flag` that no recipe it reaches declares. Some names
      are reserved (see "Reserved flags" below).
    * `aliases` - `[alias: "cookbook"]`, short names for cookbooks in this
      recipe's own references (see "Cookbook aliases" below)
    * `steps` (required) - the entries below

  ## Entries

    * `"ref"` - a step: `"cookbook:path"`, or an unqualified `"path"`
      (see `Composer.Resolver` for how it is found). An unqualified name that
      matches no step is a Hex package: `"oban"` is `"hex:oban"`.
    * `{"ref", if: :flag}` - a step that runs only with `--flag`
    * `{"ref", argv: ["--opt"]}` - a step run with options, as after `--`
      on `mix composer.step.run`; combines with `if:`
    * `"hex:pkg"` / `{"hex:pkg", opts}` - a package added to `mix.exs`,
      whose own installer runs (`"hex:pkg@<spec>"` is the `@` shorthand,
      see `Composer.Ref`). Besides `if:`, `opts` may hold:
        * `argv: ["--opt"]` - arguments for the package's installer
        * `only: :dev` (or a list of atoms), `runtime: false` - dep options
        * at most one source: `version: "~> 3.5"`, `github: "owner/repo"`,
          `git: url` or `path: "../my_lib"`; with `github:` or `git:`, at
          most one of `ref:`, `branch:`, `tag:`, and `sparse:` (a string),
          `submodules:` (a boolean)

      An unqualified name accepts the same options, and is an error if it
      names a step rather than a package.
    * `{:use, "ref"}` / `{:use, "ref", if: :flag}` - another recipe's
      steps, in place. An unqualified name without a `/` (`{:use, "base"}`)
      is the recipe of that name in the same chapter.
    * `{:task, "x.y", argv}` - compose any Igniter-aware Mix task
    * `{:queue, "x.y", argv}` - run a Mix task after the changes apply

  `{:task, ...}` and `{:queue, ...}` take an optional `if:` keyword as a
  fourth element.

  ## Cookbook aliases

  `aliases: [lab: "cc_lab"]` lets the recipe write `"lab:auth/passkeys"`
  (or `{:use, "lab:auth/base"}`) for `"cc_lab:auth/passkeys"`. An
  alias is only a lookup shortcut:

    * it applies to the declaring recipe's own references, never inside a
      recipe it includes, and never on the command line
    * the target is a package cookbook's name (a string), never `cb_std`,
      `hex`, `local` or another reserved name
    * the alias is a lowercase `[a-z0-9_]` name other than `cb_std`, `hex`
      and `local`, and must not be the name of an installed cookbook
    * resolved entries, listings and `--json` show the real cookbook name

  To share aliases across the recipes of a chapter, bind them before the
  final list (see `Composer.Recipe.Chapter`).

  ## Reserved flags

  A recipe can't declare a flag named like an option of the commands that
  pass flags through to it (`reserved_flags/0`):

    * `no_commit`, the option of `mix composer.recipe.run`
    * Igniter's global switches (`yes`, `dry_run`, `only`, ...), which
      every Igniter task accepts
    * the options of `mix composer.new` (the `composer_new` archive):
      `with`, `with_args`, `install`, `composer`, `extra_dep`,
      `igniter_local`, `reset`, `dry_run` and `no_recipe`. It passes every
      other switch to the recipe, so a flag with one of these names could
      never be given there.
    * `recipe`, because a boolean flag named `recipe` would make
      `--no-recipe` mean `recipe: false`

  > #### Warning {: .warning}
  >
  > A chapter file is Elixir code, evaluated with `Code.eval_file/1`. Only
  > use recipes you wrote or trust.
  """

  defstruct [
    :id,
    :ref,
    :cookbook,
    :chapter,
    :name,
    :path,
    :shortdoc,
    :doc,
    flags: [],
    aliases: [],
    steps: []
  ]

  @segment ~r/\A[a-z0-9_]+\z/
  @archive_flags ~w(with with_args install composer extra_dep igniter_local reset dry_run no_recipe recipe)a
  @reserved_aliases ["cb_std", "hex", "local"]
  @sources [:version, :github, :git, :path]
  @git_options [:ref, :branch, :tag, :sparse, :submodules]
  @hex_options [:only, :runtime] ++ @sources ++ @git_options

  @type entry ::
          String.t()
          | {String.t(), keyword()}
          | {:use, String.t()}
          | {:use, String.t(), keyword()}
          | {:task | :queue, String.t()}
          | {:task | :queue, String.t(), [String.t()]}
          | {:task | :queue, String.t(), [String.t()], keyword()}

  @type t :: %__MODULE__{
          id: String.t(),
          ref: String.t(),
          cookbook: String.t(),
          chapter: String.t(),
          name: String.t(),
          path: Path.t(),
          shortdoc: String.t(),
          doc: String.t() | nil,
          flags: keyword(String.t()),
          aliases: keyword(String.t()),
          steps: [entry()]
        }

  @doc """
  Loads recipe `name` from the chapter file at `path`, in `cookbook`.
  """
  @spec load(Path.t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def load(path, cookbook, name) do
    with {:ok, loaded} <- Composer.Recipe.Chapter.load_all(path, cookbook) do
      Composer.Recipe.Chapter.pick(loaded, path, cookbook, name)
    end
  end

  @doc "Returns the first line of a recipe's shortdoc."
  @spec summary(t() | String.t() | nil) :: String.t()
  def summary(%__MODULE__{shortdoc: shortdoc}), do: summary(shortdoc)
  def summary(nil), do: ""
  def summary(text) when is_binary(text), do: text |> String.split("\n", parts: 2) |> hd()

  @doc """
  Validates an evaluated recipe term: a list of valid entries.

  Returns the first entry's error, as `entry_error/2` reports it.
  """
  @spec validate(term(), String.t()) :: {:ok, [entry()]} | {:error, term()}
  def validate(steps, ref) when is_list(steps) do
    Enum.find_value(steps, {:ok, steps}, fn entry ->
      case entry_error(entry, ref) do
        nil -> nil
        reason -> {:error, reason}
      end
    end)
  end

  def validate(term, ref), do: {:error, {:recipe_shape, ref, term}}

  @doc """
  Returns `nil` for a well-formed entry, or why it is not, for
  `Composer.Error.message/1`. `ref` is the recipe the entry is in.

  Old step forms are `{:legacy_form, ref, entry, suggestion}`, where
  `suggestion` is the new syntax when one can be derived. Options of a
  `{"ref", opts}` entry are checked one by one:

    * `{:unknown_entry_option, ref, entry, key}`
    * `{:bad_entry_option, ref, entry, key, value}` - a value of the wrong
      type
    * `{:hex_only_option, ref, entry, key}` - a package option on a
      qualified step reference
    * `{:multiple_sources, ref, entry, keys}`
    * `{:git_option_without_git, ref, entry, key}`
    * `{:multiple_git_refs, ref, entry, keys}` - more than one of `ref`,
      `branch` and `tag`
    * `{:source_conflict, ref, entry}` - an `@` source and a keyword source
    * `{:repo_source, ref, entry, key}` - a non-version source for a
      private-repo package (`hex:org.pkg`)

  An unqualified reference accepts the package options, since it may be a
  Hex package; `Composer.Resolver` rejects them if it names a step. An
  invalid reference string is reported as `{:invalid_ref, ...}`.
  """
  @spec entry_error(term(), String.t() | nil) :: term() | nil
  def entry_error({string, opts} = entry, ref) when is_binary(string) do
    if is_list(opts) and opts != [] and Keyword.keyword?(opts) and
         Enum.uniq(Keyword.keys(opts)) == Keyword.keys(opts) do
      case Composer.Ref.parse(string) do
        {:ok, parsed} -> options_error(entry, parsed, ref)
        {:error, reason} -> reason
      end
    else
      {:invalid_entry, ref, entry}
    end
  end

  def entry_error(entry, ref) do
    cond do
      valid_form?(entry) -> nil
      suggestion = legacy(entry) -> {:legacy_form, ref, entry, suggestion}
      true -> {:invalid_entry, ref, entry}
    end
  end

  @doc "True for a well-formed recipe entry."
  @spec valid?(term()) :: boolean()
  def valid?(entry), do: entry_error(entry, nil) == nil

  @doc """
  The options of a `{"hex:pkg", opts}` entry that describe the package:
  dependency options and source keys, without `if:` and `argv:`.
  """
  @spec package_options() :: [atom()]
  def package_options, do: @hex_options

  @doc "The keys that name where a package comes from."
  @spec source_keys() :: [atom()]
  def source_keys, do: @sources

  @doc "The keys that refine a `github:` or `git:` source."
  @spec git_keys() :: [atom()]
  def git_keys, do: @git_options

  defp valid_form?(ref) when is_binary(ref), do: true
  defp valid_form?({:use, ref}), do: is_binary(ref)
  defp valid_form?({:use, ref, opts}), do: is_binary(ref) and if_opts?(opts)
  defp valid_form?({kind, task}) when kind in [:task, :queue], do: is_binary(task)

  defp valid_form?({kind, task, argv}) when kind in [:task, :queue],
    do: is_binary(task) and argv?(argv)

  defp valid_form?({kind, task, argv, opts}) when kind in [:task, :queue],
    do: is_binary(task) and argv?(argv) and if_opts?(opts)

  defp valid_form?(_entry), do: false

  defp options_error(entry, %Composer.Ref{} = parsed, ref) do
    {_string, opts} = entry
    step? = parsed.cookbook not in [nil, "hex"]

    Enum.find_value(opts, fn {key, value} ->
      cond do
        key not in [:if, :argv | @hex_options] -> {:unknown_entry_option, ref, entry, key}
        step? and key in @hex_options -> {:hex_only_option, ref, entry, key}
        not option?(key, value) -> {:bad_entry_option, ref, entry, key, value}
        true -> nil
      end
    end) || source_error(entry, parsed, ref)
  end

  # Checks how the options combine, with the reference's own @ source.
  defp source_error({_string, opts} = entry, parsed, ref) do
    keys = Keyword.keys(opts)
    sources = Enum.filter(keys, &(&1 in @sources))
    all_keys = keys ++ Keyword.keys(parsed.source)
    git_options = Enum.filter(keys, &(&1 in @git_options))
    git_refs = Enum.filter(all_keys, &(&1 in [:ref, :branch, :tag]))
    non_version = Enum.find(sources, &(&1 != :version))

    cond do
      length(sources) > 1 ->
        {:multiple_sources, ref, entry, sources}

      sources != [] and parsed.source != [] ->
        {:source_conflict, ref, entry}

      git_options != [] and not Enum.any?(all_keys, &(&1 in [:github, :git])) ->
        {:git_option_without_git, ref, entry, hd(git_options)}

      length(git_refs) > 1 ->
        {:multiple_git_refs, ref, entry, git_refs}

      non_version && Composer.Ref.repo_package?(parsed.path) ->
        {:repo_source, ref, entry, non_version}

      true ->
        nil
    end
  end

  defp option?(:if, flag), do: flag?(flag)
  defp option?(:argv, argv), do: argv?(argv)
  defp option?(:only, envs) when is_list(envs), do: envs != [] and Enum.all?(envs, &flag?/1)
  defp option?(:only, env), do: flag?(env)
  defp option?(:runtime, value), do: is_boolean(value)
  defp option?(:submodules, value), do: is_boolean(value)
  defp option?(:sparse, value), do: is_binary(value) and value != ""

  defp option?(:version, requirement),
    do: is_binary(requirement) and match?({:ok, _}, Version.parse_requirement(requirement))

  defp option?(key, value) when key in [:github, :git, :path, :ref, :branch, :tag],
    do: is_binary(value) and String.trim(value) != ""

  @doc """
  Returns the flag names no recipe may declare (see "Reserved flags").
  """
  @spec reserved_flags() :: [atom()]
  def reserved_flags, do: Enum.uniq(own_reserved() ++ @archive_flags)

  @doc "True when `flag` is reserved only by `mix composer.new`."
  @spec archive_flag?(atom()) :: boolean()
  def archive_flag?(flag), do: flag in @archive_flags and flag not in own_reserved()

  defp own_reserved,
    do: [:no_commit | Keyword.keys(Igniter.Mix.Task.Info.global_options()[:switches])]

  @doc "Returns every `if:` flag in `steps`, in order, without duplicates."
  @spec if_flags([entry()]) :: [atom()]
  def if_flags(steps), do: steps |> Enum.map(&own_flag/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  @doc """
  Returns the cookbook that `name`, the cookbook part of a reference, is an
  alias for in `recipe`, or `nil`.
  """
  @spec alias_target(t(), String.t() | nil) :: String.t() | nil
  def alias_target(_recipe, nil), do: nil

  def alias_target(%__MODULE__{aliases: aliases}, name) do
    Enum.find_value(aliases, fn {short, target} -> Atom.to_string(short) == name && target end)
  end

  @doc """
  Validates a recipe's `aliases` keyword list, returning every problem as
  an error reason for `Composer.Error.message/1`.
  """
  @spec validate_aliases(keyword(), String.t()) :: [term()]
  def validate_aliases(aliases, ref) do
    names = Keyword.keys(aliases)

    duplicates =
      for {name, count} <- Enum.frequencies(names), count > 1, do: {:duplicate_alias, ref, name}

    problems =
      aliases
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.flat_map(fn {name, target} -> alias_problems(name, target, ref) end)

    problems ++ Enum.sort(duplicates)
  end

  defp alias_problems(name, target, ref) do
    string = Atom.to_string(name)

    name_problem =
      cond do
        not Regex.match?(@segment, string) -> [{:invalid_alias, ref, name}]
        string in @reserved_aliases -> [{:reserved_alias, ref, name}]
        true -> []
      end

    target_problem =
      cond do
        is_atom(target) and not is_nil(target) and not is_boolean(target) ->
          [{:alias_atom_target, ref, name, target}]

        not is_binary(target) or not Regex.match?(@segment, target) or
            target in Composer.Cookbook.reserved() ->
          [{:invalid_alias_target, ref, name, target}]

        true ->
          []
      end

    name_problem ++ target_problem
  end

  @doc """
  Returns the cookbook parts of the qualified references in `steps` (step
  and `{:use, ...}` references), without duplicates.
  """
  @spec cookbooks_referenced([entry()]) :: [String.t()]
  def cookbooks_referenced(steps) do
    steps
    |> Enum.flat_map(fn
      ref when is_binary(ref) -> [ref]
      {ref, _opts} when is_binary(ref) -> [ref]
      {:use, ref} -> [ref]
      {:use, ref, _opts} -> [ref]
      _ -> []
    end)
    |> Enum.flat_map(fn ref ->
      case Composer.Ref.parse(ref) do
        {:ok, %Composer.Ref{cookbook: cookbook}} when is_binary(cookbook) -> [cookbook]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  @doc "Returns an entry's own `if:` flag, or `nil`."
  @spec own_flag(entry()) :: atom() | nil
  def own_flag({ref, opts}) when is_binary(ref), do: opts[:if]
  def own_flag({:use, _ref, opts}), do: opts[:if]
  def own_flag({_kind, _task, _argv, opts}), do: opts[:if]
  def own_flag(_entry), do: nil

  defp argv?(argv), do: is_list(argv) and Enum.all?(argv, &is_binary/1)

  defp if_opts?(opts) do
    is_list(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) == [:if] and
      flag?(opts[:if])
  end

  @doc false
  def flag?(flag), do: is_atom(flag) and not is_nil(flag) and not is_boolean(flag)

  # Returns the new syntax for an old step form (or a generic hint), or nil
  # when the entry is not a recognizable old form.
  defp legacy({kind, name}) when kind in [:add, :gen] and is_atom(name), do: inspect("#{name}")
  defp legacy({:remove, name}) when is_atom(name), do: inspect("remove_#{name}")
  defp legacy({:install, name}) when is_atom(name), do: inspect("hex:#{name}")

  defp legacy({kind, name, opts})
       when kind in [:add, :gen, :remove, :install] and is_list(opts) do
    base = legacy({kind, name}) || inspect(to_string(name))

    base =
      case opts[:from] do
        nil -> base
        cookbook -> inspect("#{Macro.underscore(inspect(cookbook))}:#{name}")
      end

    case opts[:if] do
      nil -> base
      flag -> "{#{base}, if: #{inspect(flag)}}"
    end
  end

  defp legacy({:use, name}) when is_atom(name), do: "{:use, #{inspect(to_string(name))}}"

  defp legacy({:use, name, opts}) when is_atom(name) and is_list(opts),
    do: "{:use, #{inspect(to_string(name))}, if: #{inspect(opts[:if])}}"

  defp legacy({:composer, _module}),
    do: "a {:use, \"cookbook:recipe\"} include of a recipe file"

  defp legacy({:composer, _module, _opts}),
    do: "a {:use, \"cookbook:recipe\", if: :flag} include of a recipe file"

  defp legacy(module) when is_atom(module) and not is_nil(module) and not is_boolean(module) do
    if match?("Elixir." <> _, Atom.to_string(module)),
      do: "a step in a cookbook, referenced as \"cookbook:path\""
  end

  defp legacy({module, opts}) when is_atom(module) and is_list(opts), do: legacy(module)
  defp legacy(_entry), do: nil
end
