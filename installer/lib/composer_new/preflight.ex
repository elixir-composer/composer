defmodule ComposerNew.Preflight do
  @moduledoc """
  The checks `mix composer.new` makes before it creates anything, and
  reports all at once:

    * APP doesn't exist yet, unless `--reset` is given
    * the `igniter_new` archive is installed, at 0.5.32 or later: that is
      the first release that takes `--no-git` without also passing it to
      each `--install` package's installer
    * the `--with` task is available (`phx.new` needs the `phx_new`
      archive)
    * `git` is on the PATH
    * each cookbook installed from Hex is a Hex package, the one
      `--recipe` names included. If Hex can't be reached, or
      `HEX_OFFLINE` is set, this only warns.

  Whether the cookbook has the recipe can't be known before it is
  installed: `mix composer.recipe.run` reports that.

  The lookups are functions in `checks`, so tests need no fakes on disk.
  """

  alias ComposerNew.Plan

  @min_igniter_new "0.5.32"

  @type checks :: [
          exists?: (Path.t() -> boolean()),
          task?: (String.t() -> boolean()),
          igniter_new_version: (-> String.t() | nil),
          executable?: (String.t() -> boolean()),
          hex_package?: (String.t() -> boolean() | :unknown)
        ]

  @doc "The minimum `igniter_new` version."
  @spec min_igniter_new() :: String.t()
  def min_igniter_new, do: @min_igniter_new

  @doc """
  Checks `plan`. Returns `{:ok, warnings}` or `{:error, problems}`, each
  a list of messages.
  """
  @spec check(Plan.t(), checks()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def check(%Plan{} = plan, checks \\ []) do
    checks = Keyword.merge(defaults(), checks)
    opts = plan.parsed.opts
    dir = plan.summary.dir

    {igniter_problems, igniter_warnings} = igniter_new(checks)
    {hex_problems, hex_warnings} = hex_cookbooks(plan.summary.cookbooks, checks)
    warnings = igniter_warnings ++ hex_warnings

    problems =
      List.wrap(
        if checks[:exists?].(dir) and not opts[:reset],
          do: "#{dir} already exists. Remove it, or pass --reset to delete it first."
      ) ++
        igniter_problems ++
        List.wrap(with_task(opts[:with], checks)) ++
        List.wrap(
          if not checks[:executable?].("git"),
            do: "git is required, but it isn't on the PATH."
        ) ++
        hex_problems

    if problems == [], do: {:ok, warnings}, else: {:error, problems}
  end

  defp igniter_new(checks) do
    if checks[:task?].("igniter.new") do
      case checks[:igniter_new_version].() do
        nil ->
          {[],
           [
             "Can't tell which igniter_new is installed; " <>
               "composer.new needs #{@min_igniter_new} or later."
           ]}

        version ->
          case Version.parse(version) do
            {:ok, parsed} ->
              if Version.compare(parsed, Version.parse!(@min_igniter_new)) == :lt,
                do: {[old_igniter_new(version)], []},
                else: {[], []}

            :error ->
              {[], ["Can't read the igniter_new version #{inspect(version)}."]}
          end
      end
    else
      {["mix igniter.new isn't available. Install it with: mix archive.install hex igniter_new"],
       []}
    end
  end

  defp old_igniter_new(version) do
    "igniter_new >= #{@min_igniter_new} is required (#{version} is installed): " <>
      "mix archive.install hex igniter_new --force"
  end

  defp hex_cookbooks(cookbooks, checks) do
    results =
      for %{hex?: true} = cookbook <- cookbooks,
          do: {cookbook, checks[:hex_package?].(cookbook.name)}

    problems = for {cookbook, false} <- results, do: not_on_hex(cookbook)

    warnings =
      for {cookbook, :unknown} <- results,
          do: "Can't check Hex for the #{cookbook.name} cookbook; installing it may fail."

    {problems, warnings}
  end

  defp not_on_hex(%{name: name, implied?: true}) do
    "--recipe names the #{name} cookbook, which isn't given with --cookbook and isn't " <>
      "on Hex. Say where it comes from: --cookbook #{name}@SOURCE"
  end

  defp not_on_hex(%{name: name}) do
    "--cookbook #{name}: there is no #{name} package on Hex. " <>
      "Give a source: --cookbook #{name}@SOURCE"
  end

  defp with_task(nil, _checks), do: nil
  defp with_task("new", _checks), do: nil

  defp with_task(task, checks) do
    if not checks[:task?].(task) do
      archive = String.replace(task, ".", "_")

      if task == "phx.new",
        do: "--with #{task} needs the #{archive} archive: mix archive.install hex #{archive}",
        else:
          "--with #{task}: there is no mix #{task} task. It probably comes from the " <>
            "#{archive} archive: mix archive.install hex #{archive}"
    end
  end

  defp defaults do
    [
      exists?: &File.exists?/1,
      task?: &(Mix.Task.get(&1) != nil),
      igniter_new_version: &igniter_new_version/0,
      executable?: &(System.find_executable(&1) != nil),
      hex_package?: &hex_package?/1
    ]
  end

  # GET https://hex.pm/api/packages/NAME: 200 is a package, 404 is none,
  # anything else (offline, rate-limited) is :unknown.
  defp hex_package?(name) do
    if System.get_env("HEX_OFFLINE") in ["1", "true"] do
      :unknown
    else
      with {:ok, _} <- Application.ensure_all_started(:inets),
           {:ok, _} <- Application.ensure_all_started(:ssl),
           {:ok, {{_, status, _}, _headers, _body}} <-
             :httpc.request(
               :get,
               {~c"https://hex.pm/api/packages/#{name}", [{~c"user-agent", ~c"composer_new"}]},
               [timeout: 10_000, connect_timeout: 5_000, ssl: ssl_options()],
               []
             ) do
        case status do
          200 -> true
          404 -> false
          _ -> :unknown
        end
      else
        _ -> :unknown
      end
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp igniter_new_version do
    Application.load(:igniter_new)

    case Application.spec(:igniter_new, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end
end
