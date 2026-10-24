defmodule ComposerNew.Command do
  @moduledoc """
  One command of a `ComposerNew.Plan`: an executable and its arguments,
  run in `cd` (`nil` for the current directory). `label` says which part
  of the run it is: `:create`, `:install`, `:record` or `:run`.
  """

  @enforce_keys [:label, :cmd, :args]
  defstruct [:label, :cmd, :args, :cd]

  @type label :: :create | :install | :record | :run
  @type t :: %__MODULE__{label: label(), cmd: String.t(), args: [String.t()], cd: Path.t() | nil}

  @doc """
  The command as a shell would take it, each argument quoted when it
  needs to be, for printing and for retry hints.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{cmd: cmd, args: args}), do: join([cmd | args])

  @doc "Joins arguments into one shell-quoted line."
  @spec join([String.t()]) :: String.t()
  def join(args), do: Enum.map_join(args, " ", &escape/1)

  @doc "Quotes `arg` for a POSIX shell, unless it is made of safe characters only."
  @spec escape(String.t()) :: String.t()
  def escape(""), do: "''"

  def escape(arg) do
    if Regex.match?(~r{\A[A-Za-z0-9_@%+=:,./-]+\z}, arg),
      do: arg,
      else: "'" <> String.replace(arg, "'", ~S('\'')) <> "'"
  end
end
