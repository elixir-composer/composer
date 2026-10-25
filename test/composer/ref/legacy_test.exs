defmodule Composer.Ref.LegacyTest do
  use ExUnit.Case, async: true

  alias Composer.Ref.Legacy, as: Ref

  test "parses qualified and unqualified references, normalizing - to _" do
    assert {:ok, %Ref{cookbook: "cc_lab", path: "ash/postgres"}} =
             Ref.parse("cc_lab:ash/postgres")

    assert {:ok, %Ref{cookbook: nil, path: "daisy_ui"}} = Ref.parse("daisy-ui")
    assert {:ok, %Ref{cookbook: "hex", path: "oban.oban_pro"}} = Ref.parse("hex:oban.oban_pro")
    assert Ref.to_string(Ref.parse!("cb_std:setup/credo")) == "cb_std:setup/credo"
  end

  test "rejects malformed references" do
    for bad <- [
          "",
          "a:b:c",
          "CbStd:credo",
          "cb_std:",
          "cb_std:a//b",
          "cb_std:a.b",
          "hex:a/b",
          "x y"
        ] do
      assert {:error, {:invalid_ref, ^bad, _why}} = Ref.parse(bad),
             "expected #{inspect(bad)} to fail"
    end
  end

  describe "@ sources" do
    test "versions follow Igniter: exact, partial, or a requirement kept as written" do
      assert Ref.parse!("hex:ash@3.5.0").source == [version: "== 3.5.0"]
      assert Ref.parse!("hex:ash@3.5").source == [version: "~> 3.0"]
      assert Ref.parse!("hex:ash@0.5").source == [version: "~> 0.5"]
      assert Ref.parse!("hex:ash@~> 3.5").source == [version: "~> 3.5"]
      assert Ref.parse!("hex:oban.oban_pro@1.0").source == [version: "~> 1.0"]
    end

    test "github:, git: and path: sources" do
      assert Ref.parse!("hex:ash@github:ash-project/ash").source == [github: "ash-project/ash"]
      assert Ref.parse!("hex:x@github:a/b@main").source == [github: "a/b", ref: "main"]

      assert Ref.parse!("hex:x@git:https://u@host/a-b.git").source == [
               git: "https://u@host/a-b.git"
             ]

      assert Ref.parse!("hex:my_lib@path:../my_lib").source == [path: "../my_lib"]
    end

    test "only the package name is normalized; the spec is split on the first @ only" do
      assert {:ok, %Ref{cookbook: "hex", path: "live_debugger", source: source}} =
               Ref.parse("hex:live-debugger@github:software-mansion/live-debugger")

      assert source == [github: "software-mansion/live-debugger"]

      assert Ref.parse!("hex:x@git:git@github.com:a/b.git").source ==
               [git: "git@github.com:a/b.git"]
    end

    test "to_string/1 renders the source in @ form" do
      for ref <- ["hex:x@github:a/b@main", "hex:x@path:../x", "hex:x@git:git@h:a/b.git"] do
        assert Ref.to_string(Ref.parse!(ref)) == ref
      end

      assert Ref.to_string(Ref.parse!("hex:ash@3.5.0")) == "hex:ash@== 3.5.0"
    end

    test "malformed specs name the reference" do
      for bad <- [
            "hex:a@",
            "hex:a@foo:bar",
            "hex:a@github:",
            "hex:a@path:",
            "hex:a@github:nope",
            "hex:a@github:a/b@",
            "hex:a@banana",
            "hex:org.pkg@path:../x"
          ] do
        assert {:error, {:invalid_ref, ^bad, _why}} = Ref.parse(bad),
               "expected #{inspect(bad)} to fail"
      end
    end

    test "an @ outside hex: is invalid, suggesting the hex: form" do
      for bad <- ["ash@3.5", "cb_std:x@1"] do
        assert {:error, {:invalid_ref, ^bad, why}} = Ref.parse(bad)
        assert why =~ "hex:"
      end

      assert {:error, {:invalid_ref, _, why}} = Ref.parse("ash@3.5")
      assert why =~ ~s("hex:ash@3.5")
    end
  end
end
