defmodule Composer.LSP.Session do
  @moduledoc """
  The language server's state process, holding a `Composer.LSP.Workspace`.

  GenLSP runs requests in tasks, so state can't live in the server.
  Requests read a `snapshot/1`; document notifications update it. Lints
  and reloads run in tasks the Session starts, one lint at a time, so
  hover, goto and completion never wait on them. When a lint or reload
  finishes, the Session sends the server:

    * `{:composer_lsp, {:publish, [{uri, path, diagnostics}], encoding}}`
    * `{:composer_lsp, {:reloaded, {:ok, count} | {:error, message}}}`

  The Session makes no GenLSP calls.

  ## Options

    * `:server` - the pid messages are sent to (required)
    * `:cookbooks`, `:local_dir`, `:root`, `:project`, `:entries` - the
      workspace's (see `Composer.LSP.Workspace`)
    * `:lint` - `fn path, args -> result end`, by default
      `Composer.LSP.Diagnostics.run/2`
    * `:discover` - `fn -> {:ok, cookbooks} | {:error, message} end`, run
      by `reload/1`, by default `Composer.LSP.reload_cookbooks/0`
  """

  use GenServer

  require Logger

  alias Composer.LSP.{Convert, Diagnostics, Workspace}

  @doc "Starts a Session linked to the caller."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Records an opened document and lints it from disk."
  def open(session, uri, text), do: GenServer.cast(session, {:open, uri, text})

  @doc "Replaces a document's text."
  def change(session, uri, text), do: GenServer.cast(session, {:change, uri, text})

  @doc "Forgets a closed document's text."
  def close(session, uri), do: GenServer.cast(session, {:close, uri})

  @doc "Lints a saved document from disk."
  def saved(session, uri), do: GenServer.cast(session, {:saved, uri})

  @doc "Sets the negotiated position encoding."
  def encoding(session, encoding), do: GenServer.call(session, {:encoding, encoding})

  @doc "What a request needs; see `Composer.LSP.Workspace.snapshot/1`."
  def snapshot(session), do: GenServer.call(session, :snapshot)

  @doc """
  Recompiles and rediscovers the cookbooks in a task. Returns `:ok`, or
  `:running` when a reload is already running.
  """
  def reload(session), do: GenServer.call(session, :reload)

  # -- server -------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    {:ok, tasks} = Task.Supervisor.start_link()

    ws =
      Workspace.new(
        Keyword.take(opts, [:cookbooks, :local_dir, :root, :project, :entries])
        |> Enum.reject(fn {_key, value} -> value == nil end)
      )

    {:ok,
     %{
       ws: ws,
       server: Keyword.fetch!(opts, :server),
       lint: Keyword.get(opts, :lint, &Diagnostics.run/2),
       discover: Keyword.get(opts, :discover, &Composer.LSP.reload_cookbooks/0),
       tasks: tasks,
       lint_task: nil,
       reload_task: nil
     }}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, Workspace.snapshot(state.ws), state}

  def handle_call({:encoding, encoding}, _from, state),
    do: {:reply, :ok, %{state | ws: Workspace.encoding(state.ws, encoding)}}

  def handle_call(:reload, _from, %{reload_task: nil} = state) do
    discover = state.discover
    task = Task.Supervisor.async_nolink(state.tasks, fn -> discover.() end)
    {:reply, :ok, %{state | reload_task: task.ref}}
  end

  def handle_call(:reload, _from, state), do: {:reply, :running, state}

  @impl GenServer
  def handle_cast({:open, uri, text}, state) do
    state = %{state | ws: Workspace.open(state.ws, uri, text)}
    {:noreply, lint(state, uri)}
  end

  def handle_cast({:change, uri, text}, state),
    do: {:noreply, %{state | ws: Workspace.change(state.ws, uri, text)}}

  def handle_cast({:close, uri}, state),
    do: {:noreply, %{state | ws: Workspace.close(state.ws, uri)}}

  def handle_cast({:saved, uri}, state), do: {:noreply, lint(state, uri)}

  @impl GenServer
  def handle_info({ref, result}, %{lint_task: {ref, path, generation}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, path, generation, result)}
  end

  def handle_info({ref, result}, %{reload_task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, reloaded(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{lint_task: {ref, path, gen}} = state) do
    Logger.error("composer-ls: the lint of #{path} crashed: #{Exception.format_exit(reason)}")
    {:noreply, finish(state, path, gen, {:error, reason})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{reload_task: ref} = state) do
    {:noreply, reloaded(state, {:error, Exception.format_exit(reason)})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- lints --------------------------------------------------------------

  defp lint(state, uri) do
    case Convert.uri_to_path(uri) do
      nil -> state
      path -> start_next(%{state | ws: Workspace.enqueue_lint(state.ws, path)})
    end
  end

  defp start_next(state) do
    case Workspace.next_lint(state.ws) do
      {:ok, {path, generation, args}, ws} ->
        lint = state.lint
        task = Task.Supervisor.async_nolink(state.tasks, fn -> lint.(path, args) end)
        %{state | ws: ws, lint_task: {task.ref, path, generation}}

      {:none, ws} ->
        %{state | ws: ws}
    end
  end

  defp finish(state, path, generation, result) do
    {publish, ws} = Workspace.finish_lint(state.ws, path, generation, result)

    if is_list(publish) and publish != [],
      do: send(state.server, {:composer_lsp, {:publish, publish, ws.encoding}})

    start_next(%{state | ws: ws, lint_task: nil})
  end

  # -- reload -------------------------------------------------------------

  defp reloaded(state, result) do
    state = %{state | reload_task: nil}

    case result do
      {:ok, cookbooks} ->
        entries = Enum.flat_map(cookbooks, &Composer.Index.entries/1)
        send(state.server, {:composer_lsp, {:reloaded, {:ok, length(cookbooks)}}})
        %{state | ws: Workspace.reloaded(state.ws, cookbooks, entries)}

      {:error, message} ->
        send(state.server, {:composer_lsp, {:reloaded, {:error, message}}})
        state
    end
  end
end
