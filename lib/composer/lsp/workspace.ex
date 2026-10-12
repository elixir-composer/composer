defmodule Composer.LSP.Workspace do
  @moduledoc """
  The language server's state, as a struct and pure transitions;
  `Composer.LSP.Session` holds it in a process.

    * `cookbooks` - the code cookbooks, discovered without local
    * `local_dir` - the local config directory
    * `root`, `project` - the host project's directory and app name
    * `encoding` - the negotiated position encoding
    * `entries` - the code cookbooks' completion entries
      (as in the completion index, `Composer.Index`)
    * `buffers` - open documents, `%{path => %{uri, text}}`
    * `uris` - the client's URI of each path it opened, to publish with
    * `generation` - per path, bumped by each save; a lint result for an
      older generation is dropped
    * `published` - the paths whose last published diagnostics were not
      empty
    * `dependents` - per saved path, the files last linted with it
    * `queue`, `running` - lints run one at a time; a queued path is
      queued once
  """

  alias Composer.LSP.Convert

  defstruct cookbooks: [],
            local_dir: nil,
            root: nil,
            project: nil,
            encoding: :utf16,
            entries: [],
            buffers: %{},
            uris: %{},
            generation: %{},
            published: MapSet.new(),
            dependents: %{},
            queue: [],
            running: nil

  @type t :: %__MODULE__{}

  @typedoc "What to publish: the URI, path and diagnostics of each file."
  @type publish :: [{String.t(), Path.t(), [Composer.Lint.Diagnostic.t()]}]

  @doc "A workspace from `cookbooks`, `local_dir`, `root`, `project` and `entries`."
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc "Records an opened document."
  @spec open(t(), String.t(), String.t()) :: t()
  def open(ws, uri, text) do
    case Convert.uri_to_path(uri) do
      nil ->
        ws

      path ->
        %{
          ws
          | buffers: Map.put(ws.buffers, path, %{uri: uri, text: text}),
            uris: Map.put(ws.uris, path, uri)
        }
    end
  end

  @doc "Replaces an open document's text (full sync)."
  @spec change(t(), String.t(), String.t()) :: t()
  def change(ws, uri, text), do: open(ws, uri, text)

  @doc "Forgets a closed document's text. Its URI is kept for publishing."
  @spec close(t(), String.t()) :: t()
  def close(ws, uri) do
    case Convert.uri_to_path(uri) do
      nil -> ws
      path -> %{ws | buffers: Map.delete(ws.buffers, path)}
    end
  end

  @doc "Queues a lint of `path`, overtaking any earlier lint of it."
  @spec enqueue_lint(t(), Path.t()) :: t()
  def enqueue_lint(ws, path) do
    queue = if path in ws.queue, do: ws.queue, else: ws.queue ++ [path]
    %{ws | generation: Map.update(ws.generation, path, 1, &(&1 + 1)), queue: queue}
  end

  @doc """
  Takes the next lint to run, unless one is running: `{:ok, {path,
  generation, args}, ws}`, where `args` is what
  `Composer.LSP.Diagnostics.run/2` takes; or `{:none, ws}`.
  """
  @spec next_lint(t()) :: {:ok, {Path.t(), integer(), map()}, t()} | {:none, t()}
  def next_lint(%{running: nil, queue: [path | rest]} = ws) do
    generation = Map.fetch!(ws.generation, path)

    args = %{
      cookbooks: ws.cookbooks,
      local_dir: ws.local_dir,
      root: ws.root,
      known_dependents: Map.get(ws.dependents, path, [])
    }

    {:ok, {path, generation, args}, %{ws | queue: rest, running: {path, generation}}}
  end

  def next_lint(ws), do: {:none, ws}

  @doc """
  Records the result of the lint of `path` at `generation`, returning what
  to publish, or `:stale` when a newer save has overtaken it.

  Every file with diagnostics is published, and so is the saved file
  and each file whose last published diagnostics were not empty: an
  empty list clears them.
  """
  @spec finish_lint(t(), Path.t(), integer(), term()) :: {publish() | :stale, t()}
  def finish_lint(ws, path, generation, result) do
    ws = %{ws | running: nil}

    cond do
      Map.get(ws.generation, path) != generation ->
        {:stale, ws}

      match?({:ok, _results, _dependents}, result) ->
        {:ok, results, dependents} = result

        publish =
          for {file, diagnostics} <- Enum.sort(results),
              diagnostics != [] or file == path or MapSet.member?(ws.published, file),
              do: {uri(ws, file), file, diagnostics}

        published =
          Enum.reduce(results, ws.published, fn
            {file, []}, acc -> MapSet.delete(acc, file)
            {file, _}, acc -> MapSet.put(acc, file)
          end)

        {publish,
         %{ws | published: published, dependents: Map.put(ws.dependents, path, dependents)}}

      true ->
        {[], ws}
    end
  end

  @doc "Swaps in reloaded cookbooks and their completion entries."
  @spec reloaded(t(), list(), list()) :: t()
  def reloaded(ws, cookbooks, entries), do: %{ws | cookbooks: cookbooks, entries: entries}

  @doc "Sets the negotiated position encoding."
  @spec encoding(t(), Composer.LSP.Position.encoding()) :: t()
  def encoding(ws, encoding), do: %{ws | encoding: encoding}

  @doc "The client's URI for `path`, or one built from the path."
  @spec uri(t(), Path.t()) :: String.t()
  def uri(ws, path), do: Map.get_lazy(ws.uris, path, fn -> Convert.path_to_uri(path) end)

  @doc """
  What a request needs, read without waiting on lints: the cookbooks,
  local dir, host, encoding, completion entries and open buffers.
  """
  @spec snapshot(t()) :: map()
  def snapshot(ws) do
    Map.take(ws, [:cookbooks, :local_dir, :root, :project, :encoding, :entries, :buffers])
  end
end
