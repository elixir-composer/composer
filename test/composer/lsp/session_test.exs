defmodule Composer.LSP.SessionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Composer.LSP.Session

  @uri "file:///r/recipes/ash.exs"

  # A lint that reports which save it saw, blocking until released.
  defp gated_lint(test) do
    fn path, _args ->
      send(test, {:linting, self()})
      receive do: (:go -> :ok)
      {:ok, %{path => [%Composer.Lint.Diagnostic{code: :typo, related: []}]}, []}
    end
  end

  test "two quick saves of one file publish once, the newer result" do
    test = self()
    {:ok, session} = Session.start_link(server: test, lint: gated_lint(test))

    Session.saved(session, @uri)
    assert_receive {:linting, first}
    Session.saved(session, @uri)
    send(first, :go)

    assert_receive {:linting, second}
    refute_received {:composer_lsp, _}
    send(second, :go)

    assert_receive {:composer_lsp, {:publish, [{@uri, "/r/recipes/ash.exs", [_]}], :utf16}}, 2000
    refute_receive {:composer_lsp, _}, 50
  end

  test "a lint that raises is logged and the Session lives on" do
    test = self()

    lint = fn path, _args ->
      if path =~ "boom", do: raise("boom"), else: {:ok, %{path => []}, []}
    end

    {:ok, session} = Session.start_link(server: test, lint: lint)

    log =
      capture_log(fn ->
        Session.saved(session, "file:///r/recipes/boom.exs")
        Session.saved(session, @uri)
        assert_receive {:composer_lsp, {:publish, [{@uri, _, []}], _}}, 2000
      end)

    assert log =~ "boom.exs crashed"
    assert Process.alive?(session)
  end

  test "requests read a snapshot while a lint runs" do
    test = self()
    {:ok, session} = Session.start_link(server: test, lint: gated_lint(test), project: "app")

    Session.open(session, @uri, "[]")
    assert_receive {:linting, lint}

    assert %{project: "app", buffers: %{"/r/recipes/ash.exs" => %{text: "[]"}}} =
             Session.snapshot(session)

    send(lint, :go)
  end

  test "reload swaps the cookbooks, and one reload runs at a time" do
    test = self()
    cookbooks = [Composer.Cookbook.from_module(Composer.Core)]

    discover = fn ->
      send(test, {:discovering, self()})
      receive do: (:go -> {:ok, cookbooks})
    end

    {:ok, session} = Session.start_link(server: test, discover: discover)

    assert Session.reload(session) == :ok
    assert_receive {:discovering, task}
    assert Session.reload(session) == :running
    send(task, :go)

    assert_receive {:composer_lsp, {:reloaded, {:ok, 1}}}, 2000
    snapshot = Session.snapshot(session)
    assert snapshot.cookbooks == cookbooks
    assert Enum.any?(snapshot.entries, &match?({"step", "core:setup/credo", _}, &1))
  end

  test "a failed reload keeps the cookbooks" do
    {:ok, session} =
      Session.start_link(server: self(), cookbooks: [:old], discover: fn -> {:error, "nope"} end)

    Session.reload(session)
    assert_receive {:composer_lsp, {:reloaded, {:error, "nope"}}}, 2000
    assert Session.snapshot(session).cookbooks == [:old]
  end
end
