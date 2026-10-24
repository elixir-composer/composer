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

  The lookups are functions in `checks`, so tests need no fakes on disk.
  """

  alias ComposerNew.Plan

  @min_igniter_new "0.5.32"

  @type checks :: [
          exists?: (Path.t() -> boolean()),
          task?: (String.t() -> boolean()),
          igniter_new_version: (-> String.t() | nil),
          executable?: (String.t() -> boolean())
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

    {igniter_problems, warnings} = igniter_new(checks)

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
        )

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
      executable?: &(System.find_executable(&1) != nil)
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
