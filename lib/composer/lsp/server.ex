defmodule Composer.LSP.Server do
  @moduledoc """
  The GenLSP server of `composer-ls`; the only module that uses GenLSP.

  It adapts the protocol to plain modules: state lives in
  `Composer.LSP.Session` (GenLSP runs requests in tasks), positions are
  converted at this boundary (`Composer.LSP.Position`), and everything
  else is `Composer.LSP.Cursor`, `Lookup`, `Hover`, `Definition`,
  `Complete`, `Actions` and `Convert`, which build plain maps this
  module turns into GenLSP structures.

  ## Options

  The `Composer.LSP.Session` options (`:cookbooks`, `:root`,
  `:project`, `:entries`, `:lint`, `:discover`), GenLSP's
  (`:buffer`, `:assigns`, `:task_supervisor`, `:name`), and
  `:halt_on_exit`, which halts the VM on the `exit` notification.
  """

  use GenLSP

  alias Composer.LSP.{
    Actions,
    Complete,
    Convert,
    Cursor,
    Definition,
    Hover,
    Lookup,
    Position,
    Session
  }

  alias GenLSP.Enumerations.{
    CodeActionKind,
    CompletionItemKind,
    MarkupKind,
    MessageType,
    TextDocumentSyncKind
  }

  alias GenLSP.Notifications.{
    Exit,
    Initialized,
    TextDocumentDidChange,
    TextDocumentDidClose,
    TextDocumentDidOpen,
    TextDocumentDidSave,
    TextDocumentPublishDiagnostics,
    WindowShowMessage
  }

  alias GenLSP.Requests.{
    Initialize,
    Shutdown,
    TextDocumentCodeAction,
    TextDocumentCompletion,
    TextDocumentDefinition,
    TextDocumentDocumentLink,
    TextDocumentHover,
    WorkspaceExecuteCommand
  }

  alias GenLSP.Structures, as: S

  @session_opts [:cookbooks, :root, :project, :entries, :lint, :discover]
  @lsp_opts [:buffer, :assigns, :task_supervisor, :name]

  @doc """
  Runs the server on stdio and blocks. Only the buffer, started first,
  writes to stdout: every process started after it has stderr as its
  group leader.
  """
  def run(opts) do
    {:ok, buffer} = GenLSP.Buffer.start_link([])
    Process.group_leader(self(), Process.whereis(:standard_error))
    {:ok, assigns} = GenLSP.Assigns.start_link()
    {:ok, tasks} = Task.Supervisor.start_link()

    {:ok, _server} =
      start_link(
        opts ++ [buffer: buffer, assigns: assigns, task_supervisor: tasks, halt_on_exit: true]
      )

    Process.sleep(:infinity)
  end

  @doc "Starts the server; see the module doc for `opts`."
  def start_link(opts) do
    {lsp_opts, init_args} = Keyword.split(opts, @lsp_opts)
    GenLSP.start_link(__MODULE__, init_args, lsp_opts)
  end

  @impl GenLSP
  def init(lsp, opts) do
    {:ok, session} = Session.start_link([server: self()] ++ Keyword.take(opts, @session_opts))

    {:ok,
     assign(lsp,
       session: session,
       halt_on_exit: Keyword.get(opts, :halt_on_exit, false),
       host: %{project: opts[:project], root: opts[:root]}
     )}
  end

  # -- requests -------------------------------------------------------------

  @impl GenLSP
  def handle_request(%Initialize{params: params}, lsp) do
    {encoding, wire} = Position.negotiate(position_encodings(params))
    :ok = Session.encoding(session(lsp), encoding)

    {:reply,
     %S.InitializeResult{
       capabilities: %S.ServerCapabilities{
         position_encoding: wire,
         text_document_sync: %S.TextDocumentSyncOptions{
           open_close: true,
           change: TextDocumentSyncKind.full(),
           save: %S.SaveOptions{include_text: false}
         },
         hover_provider: true,
         definition_provider: true,
         document_link_provider: %S.DocumentLinkOptions{resolve_provider: false},
         completion_provider: %S.CompletionOptions{trigger_characters: ["\"", ":", "/"]},
         code_action_provider: %S.CodeActionOptions{
           code_action_kinds: [CodeActionKind.quick_fix()]
         },
         execute_command_provider: %S.ExecuteCommandOptions{commands: ["composer.reload"]}
       },
       server_info: %{name: "composer-ls"}
     }, lsp}
  end

  def handle_request(%Shutdown{}, lsp), do: {:reply, nil, lsp}

  def handle_request(%TextDocumentHover{params: params}, lsp) do
    reply =
      with %{} = at <- at(lsp, params.text_document.uri, params.position),
           cursor when cursor != nil <- Cursor.at(at.text, at.path, at.line, at.column),
           result = Lookup.resolve(cursor, at.path, at.snapshot),
           text when is_binary(text) <-
             Hover.render(result, host(lsp), Lookup.cookbooks(at.snapshot)) do
        %S.Hover{
          contents: %S.MarkupContent{kind: MarkupKind.markdown(), value: text},
          range: range(cursor.range, at.snapshot.encoding, at.text)
        }
      else
        _ -> nil
      end

    {:reply, reply, lsp}
  end

  def handle_request(%TextDocumentDefinition{params: params}, lsp) do
    reply =
      with %{} = at <- at(lsp, params.text_document.uri, params.position),
           cursor when cursor != nil <- Cursor.at(at.text, at.path, at.line, at.column),
           result = Lookup.resolve(cursor, at.path, at.snapshot),
           buffer = %{text: at.text, path: at.path, recipe: cursor.recipe},
           {path, target} <- Definition.target(result, Lookup.cookbooks(at.snapshot), buffer) do
        text = if path == at.path, do: at.text, else: read(path)

        %S.Location{
          uri: Convert.path_to_uri(path),
          range: range(target, at.snapshot.encoding, text)
        }
      else
        _ -> nil
      end

    {:reply, reply, lsp}
  end

  def handle_request(%TextDocumentDocumentLink{params: params}, lsp) do
    reply =
      with %{} = doc <- document(lsp, params.text_document.uri) do
        for {target, url} <- Definition.links(doc.text, doc.path) do
          %S.DocumentLink{range: range(target, doc.snapshot.encoding, doc.text), target: url}
        end
      end

    {:reply, reply, lsp}
  end

  def handle_request(%TextDocumentCompletion{params: params}, lsp) do
    reply =
      with %{} = at <- at(lsp, params.text_document.uri, params.position),
           {_kind, _prefix, _range} = context <- Cursor.context(at.text, at.line, at.column) do
        entries = at.snapshot.entries
        aliases = Cursor.scan_aliases(at.text, at.line)
        buffer = Lookup.context(Lookup.cookbooks(at.snapshot), at.path)

        items =
          for item <- Complete.items(context, entries, aliases, buffer) do
            %S.CompletionItem{
              label: item.label,
              kind: completion_kind(item.kind),
              detail: item.detail,
              filter_text: item.label,
              text_edit: %S.TextEdit{
                range: range(item.range, at.snapshot.encoding, at.text),
                new_text: item.label
              }
            }
          end

        %S.CompletionList{is_incomplete: false, items: items}
      else
        _ -> nil
      end

    {:reply, reply, lsp}
  end

  def handle_request(%TextDocumentCodeAction{params: params}, lsp) do
    uri = params.text_document.uri

    reply =
      with %{} = doc <- document(lsp, uri) do
        quoted? = &starts_with_quote?(&1, doc)

        for action <- Actions.for_diagnostics(uri, params.context.diagnostics, quoted?) do
          %S.CodeAction{
            title: action.title,
            kind: action.kind,
            diagnostics: action.diagnostics,
            is_preferred: action.is_preferred,
            edit: %S.WorkspaceEdit{
              changes:
                Map.new(action.edit.changes, fn {uri, edits} ->
                  {uri, for(e <- edits, do: %S.TextEdit{range: e.range, new_text: e.new_text})}
                end)
            }
          }
        end
      end

    {:reply, reply, lsp}
  end

  def handle_request(%WorkspaceExecuteCommand{params: %{command: "composer.reload"}}, lsp) do
    if Session.reload(session(lsp)) == :running,
      do: show(lsp, MessageType.info(), "composer-ls: a reload is already running")

    {:reply, nil, lsp}
  end

  def handle_request(_request, lsp), do: {:reply, nil, lsp}

  # -- notifications --------------------------------------------------------

  @impl GenLSP
  def handle_notification(%Initialized{}, lsp) do
    %{project: project, root: root} = host(lsp)
    show(lsp, MessageType.info(), "composer-ls: host project #{project} at #{root}")
    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidOpen{params: %{text_document: doc}}, lsp) do
    Session.open(session(lsp), doc.uri, doc.text)
    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidChange{params: params}, lsp) do
    case List.last(params.content_changes) do
      %{text: text} -> Session.change(session(lsp), params.text_document.uri, text)
      _ -> :ok
    end

    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidClose{params: params}, lsp) do
    Session.close(session(lsp), params.text_document.uri)
    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidSave{params: params}, lsp) do
    Session.saved(session(lsp), params.text_document.uri)
    {:noreply, lsp}
  end

  def handle_notification(%Exit{}, lsp) do
    if assigns(lsp).halt_on_exit, do: System.halt(0)
    {:noreply, lsp}
  end

  def handle_notification(_notification, lsp), do: {:noreply, lsp}

  # -- messages from the Session --------------------------------------------

  @impl GenLSP
  def handle_info({:composer_lsp, {:publish, publish, encoding}}, lsp) do
    files =
      for {_uri, path, diagnostics} <- publish,
          file <- [path | for(d <- diagnostics, r <- d.related, do: r.file)],
          file != nil,
          uniq: true,
          do: file

    line_fun = Convert.lines_for(files)

    for {uri, path, diagnostics} <- publish do
      diagnostics =
        for d <- diagnostics do
          %{d | file: path} |> Convert.diagnostic(encoding, line_fun) |> diagnostic()
        end

      GenLSP.notify(lsp, %TextDocumentPublishDiagnostics{
        params: %S.PublishDiagnosticsParams{uri: uri, diagnostics: diagnostics}
      })
    end

    {:noreply, lsp}
  end

  def handle_info({:composer_lsp, {:reloaded, {:ok, count}}}, lsp) do
    show(lsp, MessageType.info(), "composer-ls: reloaded #{count} cookbooks")
    {:noreply, lsp}
  end

  def handle_info({:composer_lsp, {:reloaded, {:error, message}}}, lsp) do
    show(lsp, MessageType.error(), "composer-ls: reload failed: #{message}")
    {:noreply, lsp}
  end

  def handle_info(_message, lsp), do: {:noreply, lsp}

  # -- helpers --------------------------------------------------------------

  defp session(lsp), do: assigns(lsp).session
  defp host(lsp), do: assigns(lsp).host

  defp show(lsp, type, message) do
    GenLSP.notify(lsp, %WindowShowMessage{
      params: %S.ShowMessageParams{type: type, message: message}
    })
  end

  defp position_encodings(%{capabilities: %{general: %{position_encodings: encodings}}}),
    do: encodings

  defp position_encodings(_params), do: nil

  # The document at `uri`: its path, its synced text (or the file's)
  # and a snapshot of the Session.
  defp document(lsp, uri) do
    with path when is_binary(path) <- Convert.uri_to_path(uri) do
      snapshot = Session.snapshot(session(lsp))

      text =
        case snapshot.buffers do
          %{^path => %{text: text}} -> text
          _ -> read(path)
        end

      text && %{path: path, text: text, snapshot: snapshot}
    end
  end

  # The document at `uri` and the Composer line and column of `position`.
  defp at(lsp, uri, position) do
    with %{} = doc <- document(lsp, uri) do
      line = position.line + 1
      line_text = Convert.line_text(lines(doc.text), line)
      column = Position.from_lsp(line_text, position.character, doc.snapshot.encoding)
      Map.merge(doc, %{line: line, column: column})
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> text
      {:error, _} -> nil
    end
  end

  defp lines(nil), do: {}
  defp lines(text), do: text |> String.split(~r/\r?\n/) |> List.to_tuple()

  defp range(range, encoding, text) do
    lines = lines(text)
    Convert.range(range, encoding, &Convert.line_text(lines, &1)) |> range()
  end

  defp range(%{start: start, end: stop}) do
    %S.Range{start: position(start), end: position(stop)}
  end

  defp position(%{line: line, character: character}),
    do: %S.Position{line: line, character: character}

  defp diagnostic(map) do
    %S.Diagnostic{
      range: range(map.range),
      severity: map.severity,
      code: map.code,
      source: map.source,
      message: map.message,
      data: map.data,
      related_information:
        for info <- map.related_information do
          %S.DiagnosticRelatedInformation{
            location: %S.Location{uri: info.location.uri, range: range(info.location.range)},
            message: info.message
          }
        end
    }
  end

  defp completion_kind(:step), do: CompletionItemKind.function()
  defp completion_kind(:recipe), do: CompletionItemKind.module()
  defp completion_kind(:folder), do: CompletionItemKind.folder()
  defp completion_kind(:cookbook), do: CompletionItemKind.folder()
  defp completion_kind(:alias), do: CompletionItemKind.folder()
  defp completion_kind(:keyword), do: CompletionItemKind.keyword()

  # Whether the diagnostic's range starts at a `"` in the document.
  defp starts_with_quote?(diagnostic, doc) do
    %{line: line, character: character} = diagnostic.range.start
    line_text = Convert.line_text(lines(doc.text), line + 1)
    column = Position.from_lsp(line_text, character, doc.snapshot.encoding)

    line_text != nil and
      line_text |> String.graphemes() |> Enum.at(column - 1) == "\""
  end
end
