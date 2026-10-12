defmodule Composer.LSP.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Composer.LSP.Workspace

  @app "/r/recipes/app.exs"
  @ash "/r/recipes/ash.exs"

  defp lint(ws, path, result) do
    ws = Workspace.enqueue_lint(ws, path)
    {:ok, {^path, generation, _args}, ws} = Workspace.next_lint(ws)
    Workspace.finish_lint(ws, path, generation, result)
  end

  test "buffers follow open, change and close; the URI is kept" do
    ws =
      Workspace.new([])
      |> Workspace.open("file:///r/recipes/ash.exs", "one")
      |> Workspace.change("file:///r/recipes/ash.exs", "two")

    assert ws.buffers[@ash].text == "two"

    ws = Workspace.close(ws, "file:///r/recipes/ash.exs")
    assert ws.buffers == %{}
    assert Workspace.uri(ws, @ash) == "file:///r/recipes/ash.exs"
    assert Workspace.open(ws, "untitled:1", "x") == ws
  end

  test "lints run one at a time, and a queued path is queued once" do
    ws = Workspace.new([]) |> Workspace.enqueue_lint(@ash) |> Workspace.enqueue_lint(@app)
    {:ok, {@ash, 1, args}, ws} = Workspace.next_lint(ws)
    assert args.known_dependents == []
    assert {:none, ws} = Workspace.next_lint(ws)

    ws = ws |> Workspace.enqueue_lint(@app) |> Workspace.enqueue_lint(@ash)
    assert ws.queue == [@app, @ash]
  end

  test "a result overtaken by a newer save is stale" do
    ws = Workspace.enqueue_lint(Workspace.new([]), @ash)
    {:ok, {@ash, 1, _}, ws} = Workspace.next_lint(ws)
    ws = Workspace.enqueue_lint(ws, @ash)

    assert {:stale, ws} = Workspace.finish_lint(ws, @ash, 1, {:ok, %{@ash => []}, []})
    assert {:ok, {@ash, 2, _}, _ws} = Workspace.next_lint(ws)
  end

  test "a dependent fixed indirectly gets an empty list, once" do
    problem = %Composer.Lint.Diagnostic{code: :include_problems}

    {publish, ws} =
      lint(Workspace.new([]), @ash, {:ok, %{@ash => [problem], @app => [problem]}, [@app]})

    assert Enum.map(publish, &elem(&1, 1)) == [@app, @ash]
    assert MapSet.member?(ws.published, @app)

    {publish, ws} = lint(ws, @ash, {:ok, %{@ash => [], @app => []}, [@app]})
    assert [{"file:///r/recipes/app.exs", @app, []}, {_, @ash, []}] = publish
    refute MapSet.member?(ws.published, @app)

    # Clean again: the dependent, already cleared, is not published.
    {publish, _ws} = lint(ws, @ash, {:ok, %{@ash => [], @app => []}, [@app]})
    assert Enum.map(publish, &elem(&1, 1)) == [@ash]
  end

  test "the last known dependents are handed to the next lint" do
    {_publish, ws} = lint(Workspace.new([]), @ash, {:ok, %{@ash => []}, [@app]})
    ws = Workspace.enqueue_lint(ws, @ash)
    assert {:ok, {@ash, _, %{known_dependents: [@app]}}, _ws} = Workspace.next_lint(ws)
  end

  test "an ignored file publishes nothing" do
    assert {[], _ws} = lint(Workspace.new([]), "/r/mix.exs", :ignore)
  end
end
