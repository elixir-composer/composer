defmodule Composer.Editor do
  @moduledoc """
  Opens a file in the user's editor, for `mix composer.recipe.edit`.

  The command is the first of these environment variables that is set:

    * `COMPOSER_EDITOR`
    * `VISUAL`
    * `EDITOR`

  `__FILE__` and `__LINE__` in the command are replaced with the file and
  the line to open at, as in `ELIXIR_EDITOR`; a command without `__FILE__`
  gets the (shell-quoted) file appended. `__FILE__` is substituted as is,
  so it can sit inside quotes in the command:

      # Neovim in the current terminal
      export COMPOSER_EDITOR="nvim +__LINE__ __FILE__"

      # Neovim in a new Ghostty window
      export COMPOSER_EDITOR="ghostty -e 'nvim +__LINE__ __FILE__'"

  The command runs through `sh -c` and inherits the terminal (stdin,
  stdout and stderr), so a terminal editor takes it over until it exits;
  the task waits for the command to finish.
  """

  @vars ~w(COMPOSER_EDITOR VISUAL EDITOR)

  @doc "The environment variables read, in order of precedence."
  @spec vars() :: [String.t()]
  def vars, do: @vars

  @doc """
  Builds the shell command that opens `file` at `line`, from `env` (a map
  of environment variables). Returns `{:error, :no_editor}` when none of
  `vars/0` is set.
  """
  @spec command(Path.t(), pos_integer(), %{String.t() => String.t()}) ::
          {:ok, String.t()} | {:error, :no_editor}
  def command(file, line, env \\ System.get_env()) do
    case Enum.find_value(@vars, &present(env[&1])) do
      nil ->
        {:error, :no_editor}

      editor ->
        editor = String.replace(editor, "__LINE__", Integer.to_string(line))

        if String.contains?(editor, "__FILE__"),
          do: {:ok, String.replace(editor, "__FILE__", file)},
          else: {:ok, editor <> " " <> quote_arg(file)}
    end
  end

  defp present(value) when is_binary(value),
    do: if(String.trim(value) != "", do: String.trim(value))

  defp present(_value), do: nil

  @doc """
  Runs `command` attached to the terminal and waits for it to exit.
  Returns `{:error, {:exit, status}}` on a non-zero exit status.
  """
  @spec run(String.t()) :: :ok | {:error, {:exit, non_neg_integer()}}
  def run(command) do
    sh = System.find_executable("sh") || raise "sh not found on PATH"

    # :nouse_stdio talks to the port over fds 3 and 4, so the command
    # inherits the BEAM's stdin, stdout and stderr: the terminal.
    port =
      Port.open({:spawn_executable, sh}, [:nouse_stdio, :exit_status, args: ["-c", command]])

    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> {:error, {:exit, status}}
    end
  end

  defp quote_arg(arg), do: "'" <> String.replace(arg, "'", ~S('\'')) <> "'"
end
