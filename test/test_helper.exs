# Keep tests offline: dependency versions fall back to permissive ranges.
# Tasks refresh the completion index as a side effect; not in tests.
Application.put_env(:composer, :fetch_versions, false)
Application.put_env(:composer, :write_index, false)

# A GenLSP server stops the VM when its input ends, as it should under an
# editor; the language server's tests close many connections.
Application.put_env(:gen_lsp, :exit_on_end, false)

ExUnit.start(exclude: [:integration])
