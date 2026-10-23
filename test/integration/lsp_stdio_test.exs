defmodule Composer.Integration.LspStdioTest do
  # Runs `mix composer.lsp` in a real host app, over stdio, as
  # an editor does, and checks that stdout holds nothing but protocol
  # frames. It compiles every dependency, so it only runs with:
  #
  #     mix test --include integration
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  @root File.cwd!()

  # A group file that prints when it is evaluated, which lint does on
  # every save: the output must not reach stdout.
  @recipe """
  IO.puts("stray output from a recipe group")

  [
    app: [shortdoc: "App", steps: ["fake_dep:hi", "credoo"]]
  ]
  """

  setup %{tmp_dir: dir} do
    app = Path.join(dir, "host_app")
    book = Path.join(app, "lib/composer/host_app")
    File.mkdir_p!(Path.join(book, "recipes"))
    File.cp!(Path.join(@root, "mix.lock"), Path.join(app, "mix.lock"))

    File.write!(Path.join(app, "mix.exs"), """
    defmodule HostApp.MixProject do
      use Mix.Project

      def project do
        [
          app: :host_app,
          version: "0.1.0",
          deps_path: #{inspect(Path.join(@root, "deps"))},
          deps: [
            {:composer, path: #{inspect(@root)}},
            {:fake_dep, path: #{inspect(Path.join(@root, "test/fixtures/fake_dep"))}}
          ]
        ]
      end
    end
    """)

    File.write!(Path.join(app, "lib/host_app.ex"), "defmodule HostApp do\nend\n")

    File.write!(
      Path.join(app, "lib/composer/host_app.ex"),
      "defmodule Composer.HostApp do\n  use Composer.Cookbook\nend\n"
    )

    recipe = Path.join(book, "recipes/mine.exs")
    File.write!(recipe, @recipe)

    # The manifest gives the server its completion entries without
    # evaluating the group, which prints.
    env = [{"MIX_ENV", "dev"}]

    for args <- [["compile"], ["composer.cookbook.manifest"]] do
      {output, status} = System.cmd("mix", args, cd: app, env: env, stderr_to_stdout: true)
      assert status == 0, output
    end

    # Give the server's own compile some work.
    File.write!(Path.join(app, "lib/host_app.ex"), "defmodule HostApp do\n  def x, do: 1\nend\n")

    %{app: app, recipe: recipe, env: env, stderr: Path.join(dir, "stderr.log")}
  end

  test "initialize, didSave, publishDiagnostics and hover; stdout is only frames", context do
    port = start(context)
    uri = "file://" <> context.recipe

    state = send_frame(%{port: port, buffer: "", frames: []}, request(1, "initialize", init()))
    {result, state} = await(state, &match?(%{"id" => 1, "result" => _}, &1))
    assert result["result"]["capabilities"]["positionEncoding"] == "utf-16"

    state = send_frame(state, notification("initialized", %{}))
    {shown, state} = await(state, &match?(%{"method" => "window/showMessage"}, &1))
    assert shown["params"]["message"] =~ "composer-ls: host project host_app"

    item = %{uri: uri, languageId: "elixir", version: 1, text: @recipe}
    state = send_frame(state, notification("textDocument/didOpen", %{textDocument: item}))
    state = send_frame(state, notification("textDocument/didSave", %{textDocument: %{uri: uri}}))

    {published, state} =
      await(state, &match?(%{"method" => "textDocument/publishDiagnostics"}, &1))

    assert published["params"]["uri"] == uri
    assert Enum.any?(published["params"]["diagnostics"], &(&1["code"] == "typo"))

    # On the "fake_dep:hi" literal of line 4.
    position = %{line: 3, character: 35}
    params = %{textDocument: %{uri: uri}, position: position}
    state = send_frame(state, request(2, "textDocument/hover", params))
    {hover, state} = await(state, &match?(%{"id" => 2}, &1))
    assert hover["result"]["contents"]["value"] =~ "**fake_dep:hi**"
    assert hover["result"]["contents"]["value"] =~ "composer-ls · host: host_app"

    state = send_frame(state, request(3, "shutdown", nil))
    {_reply, state} = await(state, &match?(%{"id" => 3}, &1))
    state = send_frame(state, notification("exit", nil))

    state = drain(state)
    assert state.buffer == "", "stdout held more than protocol frames: #{inspect(state.buffer)}"
    assert File.read!(context.stderr) =~ "stray output from a recipe group"
  end

  defp start(%{app: app, env: env, stderr: stderr}) do
    Port.open({:spawn_executable, System.find_executable("sh")}, [
      :binary,
      :exit_status,
      args: ["-c", ~s(exec mix composer.lsp 2>>"$COMPOSER_LSP_STDERR")],
      cd: app,
      env:
        for(
          {k, v} <- [{"MIX_QUIET", "1"}, {"COMPOSER_LSP_STDERR", stderr} | env],
          do: {~c"#{k}", ~c"#{v}"}
        )
    ])
  end

  defp init do
    %{processId: nil, rootUri: nil, capabilities: %{general: %{positionEncodings: ["utf-16"]}}}
  end

  defp request(id, method, params),
    do: %{jsonrpc: "2.0", id: id, method: method, params: params}

  defp notification(method, params), do: %{jsonrpc: "2.0", method: method, params: params}

  defp send_frame(state, message) do
    body = Jason.encode!(message)
    Port.command(state.port, "Content-Length: #{byte_size(body)}\r\n\r\n" <> body)
    state
  end

  # Waits for a message matching `fun`; every byte read must be a frame.
  defp await(state, fun) do
    case Enum.find(state.frames, fun) do
      nil ->
        receive do
          {port, {:data, data}} when port == state.port ->
            await(parse(%{state | buffer: state.buffer <> data}), fun)

          {port, {:exit_status, status}} when port == state.port ->
            flunk("composer.lsp exited (#{status}); stdout so far: #{inspect(state.buffer)}")
        after
          120_000 -> flunk("no matching message; got #{inspect(state.frames)}")
        end

      found ->
        {found, %{state | frames: List.delete(state.frames, found)}}
    end
  end

  # Reads until the server exits after `exit`.
  defp drain(state) do
    receive do
      {port, {:data, data}} when port == state.port ->
        drain(parse(%{state | buffer: state.buffer <> data}))

      {port, {:exit_status, status}} when port == state.port ->
        assert status == 0
        state
    after
      30_000 -> flunk("composer.lsp did not exit")
    end
  end

  defp parse(%{buffer: buffer} = state) do
    case Regex.run(~r/\AContent-Length: (\d+)\r\n\r\n/, buffer) do
      [header, length] ->
        length = String.to_integer(length)
        rest = binary_part(buffer, byte_size(header), byte_size(buffer) - byte_size(header))

        if byte_size(rest) >= length do
          <<body::binary-size(^length), rest::binary>> = rest
          parse(%{state | buffer: rest, frames: state.frames ++ [Jason.decode!(body)]})
        else
          state
        end

      nil ->
        # A partial header is fine; anything else is stray output.
        partial? =
          String.starts_with?("Content-Length: ", buffer) or
            Regex.match?(~r/\AContent-Length: \d+\r?\n?\r?\z/, buffer)

        assert partial?, "stdout held more than protocol frames: #{inspect(buffer)}"

        state
    end
  end
end
