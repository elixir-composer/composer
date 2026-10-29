defmodule Composer.Edit.Files.Block do
  @moduledoc false

  # Marked regions for Composer.Edit.Files.ensure_block/4:
  #
  #     /* composer:begin daisyui */
  #     ...
  #     /* composer:end daisyui */

  @by_extension %{
    ".css" => {"/*", "*/"},
    ".scss" => {"/*", "*/"},
    ".js" => {"/*", "*/"},
    ".mjs" => {"/*", "*/"},
    ".ts" => {"/*", "*/"},
    ".ex" => {"#", ""},
    ".exs" => {"#", ""},
    ".sh" => {"#", ""},
    ".env" => {"#", ""},
    ".toml" => {"#", ""},
    ".yml" => {"#", ""},
    ".yaml" => {"#", ""},
    ".heex" => {"<!--", "-->"},
    ".html" => {"<!--", "-->"},
    ".eex" => {"<!--", "-->"},
    ".astral" => {"<!--", "-->"},
    ".md" => {"<!--", "-->"}
  }

  # Dotfiles have no extension as far as Path.extname/1 is concerned.
  @by_name %{".gitignore" => {"#", ""}, ".env" => {"#", ""}}

  @doc """
  Returns the `{open, close}` comment syntax for `path`: the `comment:`
  option, else by file name or extension. Raises for an unknown extension,
  which is a mistake in the step rather than drift in the target app.
  """
  def comment_for(path, opts) do
    case Keyword.get(opts, :comment) do
      {open, close} when is_binary(open) and is_binary(close) ->
        {open, close}

      nil ->
        Map.get(@by_name, Path.basename(path)) || Map.get(@by_extension, Path.extname(path)) ||
          raise ArgumentError,
                "no comment syntax is known for #{path}, so ensure_block can't write its " <>
                  "markers. Pass comment: {open, close}, or markers: false."
    end
  end

  @doc "Returns the `{begin_line, end_line}` markers for `id`, without newlines."
  def markers(comment, id), do: {marker(comment, "begin", id), marker(comment, "end", id)}

  @doc "Wraps `block` in its markers. The result ends in a newline."
  def wrap(block, comment, id) do
    {begin_line, end_line} = markers(comment, id)
    begin_line <> "\n" <> ensure_newline(block) <> end_line <> "\n"
  end

  @doc """
  Finds the marked region for `id`: `{start, stop}` byte offsets from the
  begin marker's line through the end marker's line and its newline,
  `{:unclosed, start}` for a begin marker with no end, or `nil`.

  Marker lines match tolerantly: surrounding and inner whitespace may vary.
  """
  def find(content, comment, id) do
    begin_re = marker_regex(comment, "begin", id)
    end_re = marker_regex(comment, "end", id)
    lines = offsets(content)

    case Enum.drop_while(lines, fn {line, _, _} -> not marker?(begin_re, line) end) do
      [] ->
        nil

      [{_, start, _} | rest] ->
        case Enum.find(rest, fn {line, _, _} -> marker?(end_re, line) end) do
          {_, _, stop} -> {start, stop}
          nil -> {:unclosed, start}
        end
    end
  end

  defp marker({open, ""}, word, id), do: "#{open} composer:#{word} #{id}"
  defp marker({open, close}, word, id), do: "#{open} composer:#{word} #{id} #{close}"

  defp marker_regex({open, close}, word, id) do
    Regex.compile!(
      "\\A#{Regex.escape(open)}\\s*composer:#{word}\\s+#{Regex.escape(to_string(id))}\\s*" <>
        "#{Regex.escape(close)}\\z"
    )
  end

  defp marker?(regex, line), do: Regex.match?(regex, String.trim(line))

  # [{line, start, stop}], where stop is past the line's newline.
  defp offsets(content) do
    size = byte_size(content)

    content
    |> String.split("\n")
    |> Enum.map_reduce(0, fn line, start ->
      stop = min(start + byte_size(line) + 1, size)
      {{line, start, stop}, stop}
    end)
    |> elem(0)
  end

  defp ensure_newline(block) do
    if block == "" or String.ends_with?(block, "\n"), do: block, else: block <> "\n"
  end
end
