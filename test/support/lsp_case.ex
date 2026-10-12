defmodule Composer.Test.LSPCase do
  @moduledoc false
  # Drives Composer.LSP.Server in the test VM through GenLSP.Test (over
  # TCP). With composer.lsp's stdio test, the only test code naming GenLSP.

  use ExUnit.CaseTemplate

  using do
    quote do
      import GenLSP.Test
      import Composer.Test.LSPCase
    end
  end

  @doc """
  Starts a server with `opts` and initializes it, offering `encodings`.
  Returns the client and the initialize result.
  """
  def start_server(opts, encodings \\ ["utf-16"]) do
    server = GenLSP.Test.server(Composer.LSP.Server, opts)
    client = GenLSP.Test.client(server)

    GenLSP.Test.request(client, %{
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: %{
        processId: nil,
        rootUri: nil,
        capabilities: %{general: %{positionEncodings: encodings}}
      }
    })

    assert_receive %{"id" => 1, "result" => result}, 2000
    GenLSP.Test.notify(client, %{jsonrpc: "2.0", method: "initialized", params: %{}})
    {client, result}
  end

  @doc "Sends a request and returns its result."
  def call(client, id, method, params) do
    GenLSP.Test.request(client, %{jsonrpc: "2.0", id: id, method: method, params: params})
    assert_receive %{"id" => ^id, "result" => result}, 2000
    result
  end

  @doc "Sends a notification."
  def cast(client, method, params),
    do: GenLSP.Test.notify(client, %{jsonrpc: "2.0", method: method, params: params})

  @doc "Waits for the diagnostics published for `uri`."
  defmacro assert_diagnostics(uri, timeout \\ 5000) do
    quote do
      uri = unquote(uri)

      assert_receive %{
                       "method" => "textDocument/publishDiagnostics",
                       "params" => %{"uri" => ^uri, "diagnostics" => diagnostics}
                     },
                     unquote(timeout)

      diagnostics
    end
  end
end
