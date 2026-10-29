defmodule Composer.Edit.Files do
  @moduledoc """
  Changes to file content in the target app, for steps.

  Every function takes the igniter first and the path second, returns the
  igniter, and stages its change in the igniter, so it shows in the diff,
  in a dry run and in the composer's commit.

  `ensure_line/4`, `ensure_block/4` and `replace/5` are idempotent: a
  second run with the same arguments changes nothing and warns about
  nothing. A missing file, anchor or pattern is a warning ending in
  `(Composer.Edit.Files.<fun> was skipped)`, never a silent no-op.
  """

  alias Composer.Edit.Files.{Block, Text}

  @doc "Updates a file's raw content with a transformation function."
  def update(igniter, path, transform) do
    Igniter.update_file(igniter, path, fn source ->
      source
      |> Rewrite.Source.get(:content)
      |> transform.()
      |> then(&Rewrite.Source.update(source, :content, &1))
    end)
  end

  @doc """
  Updates a file's content, adding a loud warning instead of silently
  no-oping when the transformation changes nothing or the file is missing.

  Steps that pattern-match against `phx.new` output should use this so that
  drift in Phoenix's generators surfaces as a warning instead of silence.
  """
  def update_checked(igniter, path, transform, warning) do
    if Igniter.exists?(igniter, path) do
      igniter = Igniter.include_existing_file(igniter, path)
      source = Rewrite.source!(igniter.rewrite, path)
      content = Rewrite.Source.get(source, :content)

      if transform.(content) == content do
        Igniter.add_warning(igniter, warning)
      else
        update(igniter, path, transform)
      end
    else
      Igniter.add_warning(igniter, "#{path} not found — #{warning}")
    end
  end

  @doc """
  Creates a file unless it already exists, in the project or on disk.

  Use this rather than `Igniter.create_new_file/4` with `on_exists: :skip`,
  which overwrites a file that exists on disk but has not been read into the
  igniter yet.
  """
  def create_unless_exists(igniter, path, contents) do
    if Igniter.exists?(igniter, path),
      do: igniter,
      else: Igniter.create_new_file(igniter, path, contents)
  end

  @doc """
  Ensures one line is present in, or absent from, the file at `path`.
  Modelled on Ansible's `lineinfile`.

  The file is worked on line by line, and keeps its trailing newline (or
  lack of one). Only `\\n` line endings are supported.

  When `state: :present` (the default):

    * the first line found by `match:` is replaced in place when it differs
      from `line`, so a near miss such as `@import 'tailwindcss'` is
      normalised rather than doubled; later matches are left alone
    * without `match:`, a line counts only if it equals `line` exactly
    * when no line matches, `line` is added at `at:`

  `match:` must also match `line` itself, or every run adds it again. As a
  guard, a file that already holds `line` exactly is left alone.

  When `state: :absent`, every matching line is removed, and no match is a
  silent no-op. `line` may then be `nil` if `match:` is given.

  A missing file is created holding just `line` with `create: true`, is
  left alone for `state: :absent`, and is a warning otherwise. A missing
  anchor is a warning too, with no edit: there is no silent fallback.

  ## Options

    * `:match` - a regex; a line matching it is the line to replace or remove
    * `:at` - where a new line goes: `:append` (default), `:prepend`,
      `{:after, anchor}` or `{:before, anchor}`. An anchor is a string or
      regex, and the new line goes after or before the line holding its
      first occurrence
    * `:after` - with `at: :prepend`, a regex matched at the start of the
      file (e.g. `~r/\\A@charset[^\\n]*\\n/`); the line goes after it when it
      matches, else first
    * `:state` - `:present` (default) or `:absent`
    * `:collapse_blank` - with `state: :absent`, also remove one blank line
      directly after each removed line (default `false`)
    * `:create` - create a missing file (default `false`)
    * `:warning` - rewords the warning. Every warning ends in
      `(Composer.Edit.Files.ensure_line was skipped)` either way

  ## Examples

      # Tailwind first, after any @charset, normalising a variant import
      Files.ensure_line(igniter, "assets/styles.css", ~s(@import "tailwindcss";),
        match: ~r/^@import\\s+["']tailwindcss["']/,
        at: :prepend,
        after: ~r/\\A@charset[^\\n]*\\n/,
        create: true
      )

      # Drop the stylesheet import, and the blank line after it
      Files.ensure_line(igniter, "assets/app.ts", nil,
        match: ~r/^import\\s+["']\\.\\/styles\\.css["']/,
        state: :absent,
        collapse_blank: true
      )
  """
  @spec ensure_line(Igniter.t(), Path.t(), String.t() | nil, keyword()) :: Igniter.t()
  def ensure_line(igniter, path, line, opts \\ []) do
    opts =
      Keyword.validate!(opts, [
        :match,
        :after,
        :warning,
        at: :append,
        state: :present,
        create: false,
        collapse_blank: false
      ])

    state = state!(opts)
    match = Keyword.get(opts, :match)

    cond do
      state == :present and not is_binary(line) ->
        raise ArgumentError, "ensure_line needs a line unless state: :absent"

      state == :absent and is_nil(line) and is_nil(match) ->
        raise ArgumentError, "ensure_line with state: :absent needs a line or match:"

      is_binary(line) and String.contains?(line, "\n") ->
        raise ArgumentError, "ensure_line takes one line; use ensure_block for several"

      true ->
        :ok
    end

    matcher = if match, do: &Regex.match?(match, &1), else: &(&1 == line)

    edit(igniter, path, :ensure_line, opts, line && line <> "\n", fn content ->
      case state do
        :present -> put_line(content, path, line, matcher, opts)
        :absent -> remove_lines(content, matcher, opts[:collapse_blank])
      end
    end)
  end

  @doc """
  Ensures a multi-line block is present in, or absent from, the file at
  `path`. Modelled on Ansible's `blockinfile`.

  With markers on (the default), the block is wrapped in comment lines
  naming its `id:`:

      /* composer:begin daisyui */
      @plugin "daisyui";
      /* composer:end daisyui */

  When the markers are already there, the text between them is replaced
  with `block`, so a later composer can update it and an edit made by hand
  is restored. `state: :absent` removes the block with its markers, and is
  a silent no-op when they are missing. `id:` is required and must be
  unique within the file, so several steps can each manage a block in one
  file. The comment syntax comes from the file's extension (CSS, JS and
  TS; Elixir, shell, env, gitignore, TOML and YAML; HEEx, HTML, EEx,
  Astral and Markdown) or from `comment:`. An unknown extension without
  `comment:` raises.

  Use `markers: false` to add text that needs no comments around it and
  never changes: the block is then idempotent by substring (it is not
  added again if the file contains it anywhere), can't be updated or
  removed, and `at:` anchors splice it right after or before the anchor
  itself rather than on a line of its own. This is how
  `Composer.Templates.insert/4` works.

  ## Options

    * `:id` - names the block; required unless `markers: false`
    * `:markers` - `true` (default) or `false`
    * `:comment` - `{open, close}` comment syntax, e.g. `{"--", ""}`
    * `:at`, `:after`, `:create`, `:warning` - as for `ensure_line/4`
    * `:state` - `:present` (default) or `:absent` (needs markers)
  """
  @spec ensure_block(Igniter.t(), Path.t(), String.t(), keyword()) :: Igniter.t()
  def ensure_block(igniter, path, block, opts \\ []) do
    opts =
      Keyword.validate!(opts, [
        :id,
        :comment,
        :after,
        :warning,
        markers: true,
        at: :append,
        state: :present,
        create: false
      ])

    state = state!(opts)
    at = Keyword.fetch!(opts, :at)

    if opts[:markers] do
      id = Keyword.fetch!(opts, :id)
      comment = Block.comment_for(path, opts)
      wrapped = Block.wrap(block, comment, id)

      edit(igniter, path, :ensure_block, opts, wrapped, fn content ->
        case {state, Block.find(content, comment, id)} do
          {:absent, {start, stop}} when is_integer(start) ->
            {:ok,
             binary_part(content, 0, start) <>
               binary_part(content, stop, byte_size(content) - stop)}

          {:absent, _} ->
            :unchanged

          {:present, {:unclosed, _}} ->
            {:warn, "#{path} has a composer:begin #{id} marker but no composer:end #{id}"}

          {:present, {start, stop}} ->
            {:ok,
             binary_part(content, 0, start) <>
               wrapped <> binary_part(content, stop, byte_size(content) - stop)}

          {:present, nil} ->
            with :error <- Text.insert_lines(content, wrapped, at, opts),
                 do: {:warn, missing_anchor(at, path)}
        end
      end)
    else
      if state == :absent,
        do: raise(ArgumentError, "ensure_block with state: :absent needs markers")

      edit(igniter, path, :ensure_block, opts, block, fn content ->
        if String.contains?(content, block) do
          :unchanged
        else
          with :error <- Text.splice(content, block, at), do: {:warn, missing_anchor(at, path)}
        end
      end)
    end
  end

  @doc """
  Replaces matches of `pattern` in the file at `path`. Modelled on
  Ansible's `replace`.

  Every match is replaced unless `count:` limits it, and `replacement` may
  use back-references (`\\\\1`) or be a function, as for `Regex.replace/4`.

  `done:` says the change is already made: a regex matched against the
  content, or a 1-arity function given the content. When it holds, the call
  is a silent no-op. Otherwise no match is a warning, so **a call without
  `done:` warns on a second run**, once its first run has replaced every
  match. Give `done:` whenever the step may run again.

  ## Options

    * `:count` - replace only the first `count` matches
    * `:done` - a regex or a function; when it holds, nothing is done
    * `:warning` - rewords the warning. Every warning ends in
      `(Composer.Edit.Files.replace was skipped)` either way

  ## Example

      Files.replace(igniter, "config/dev.exs", ~r/port: 4000/, "port: 4100",
        done: ~r/port: 4100/
      )
  """
  @spec replace(Igniter.t(), Path.t(), Regex.t(), String.t() | function(), keyword()) ::
          Igniter.t()
  def replace(igniter, path, %Regex{} = pattern, replacement, opts \\ []) do
    opts = Keyword.validate!(opts, [:count, :done, :warning])

    edit(igniter, path, :replace, opts, nil, fn content ->
      cond do
        done?(opts[:done], content) ->
          :unchanged

        not Regex.match?(pattern, content) ->
          {:warn, "#{inspect(pattern)} matched nothing in #{path}"}

        true ->
          {:ok, Text.replace(content, pattern, replacement, opts[:count])}
      end
    end)
  end

  # Every content helper: read the file, compute the new content with a
  # pure function, then stage it, leave the igniter alone, or warn.
  # `created` is the content of a missing file under `create: true`.
  defp edit(igniter, path, fun, opts, created, compute) do
    {igniter, content} = read(igniter, path)

    result =
      cond do
        content -> compute.(content)
        opts[:state] == :absent -> :unchanged
        opts[:create] && created -> {:ok, created}
        true -> {:warn, "#{path} not found"}
      end

    case result do
      {:ok, ^content} -> igniter
      {:ok, new} when is_nil(content) -> Igniter.create_new_file(igniter, path, new)
      {:ok, new} -> update(igniter, path, fn _ -> new end)
      :unchanged -> igniter
      {:warn, message} -> warn(igniter, fun, opts, message)
    end
  end

  # The file must be read into the igniter before it is changed, or Igniter
  # would overwrite a file that is on disk but not yet read.
  defp read(igniter, path) do
    if Igniter.exists?(igniter, path) do
      igniter = Igniter.include_existing_file(igniter, path)
      {igniter, igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)}
    else
      {igniter, nil}
    end
  end

  # The only place a content helper warns. The suffix is always added, so
  # the golden CI job's "was skipped" pattern catches every skipped edit.
  defp warn(igniter, fun, opts, default_message) do
    message = Keyword.get(opts, :warning, default_message)
    Igniter.add_warning(igniter, "#{message} (Composer.Edit.Files.#{fun} was skipped)")
  end

  defp put_line(content, path, line, matcher, opts) do
    {lines, trailing?} = Text.lines(content)

    case Enum.find_index(lines, matcher) do
      nil ->
        if line in lines do
          :unchanged
        else
          at = opts[:at]

          with :error <- Text.insert_lines(content, line <> "\n", at, opts),
               do: {:warn, missing_anchor(at, path)}
        end

      index ->
        if Enum.at(lines, index) == line,
          do: :unchanged,
          else: {:ok, lines |> List.replace_at(index, line) |> Text.unlines(trailing?)}
    end
  end

  defp remove_lines(content, matcher, collapse_blank?) do
    {lines, trailing?} = Text.lines(content)

    case drop_lines(lines, matcher, collapse_blank?, [], false) do
      {_kept, false} -> :unchanged
      {kept, true} -> {:ok, Text.unlines(kept, trailing?)}
    end
  end

  defp drop_lines([], _matcher, _collapse?, kept, removed?), do: {Enum.reverse(kept), removed?}

  defp drop_lines([line | rest], matcher, collapse?, kept, removed?) do
    if matcher.(line) do
      rest =
        case rest do
          [next | after_next] when collapse? ->
            if String.trim(next) == "", do: after_next, else: rest

          _ ->
            rest
        end

      drop_lines(rest, matcher, collapse?, kept, true)
    else
      drop_lines(rest, matcher, collapse?, [line | kept], removed?)
    end
  end

  defp done?(nil, _content), do: false
  defp done?(%Regex{} = done, content), do: Regex.match?(done, content)
  defp done?(done, content) when is_function(done, 1), do: done.(content)

  defp state!(opts) do
    case Keyword.fetch!(opts, :state) do
      state when state in [:present, :absent] -> state
      other -> raise ArgumentError, "state: must be :present or :absent, got: #{inspect(other)}"
    end
  end

  defp missing_anchor({position, anchor}, path) do
    "could not find #{inspect(anchor)} in #{path}, so nothing was inserted #{position} it"
  end
end
