defmodule Composer.Helpers do
  @moduledoc """
  Deprecated: use the `Composer.Edit` modules instead.

  | Was                                  | Now                                   |
  |--------------------------------------|---------------------------------------|
  | `Composer.Helpers.update_file_content/3` | `Composer.Edit.Files.update/3`        |
  | `Composer.Helpers.update_file_checked/4` | `Composer.Edit.Files.update_checked/4` |
  | `Composer.Helpers.create_unless_exists/3` | `Composer.Edit.Files.create_unless_exists/3` |
  | `Composer.Helpers.app_module/1`      | `Composer.Edit.Project.app_module/1`  |
  | `Composer.Helpers.app_web_module/1`  | `Composer.Edit.Project.app_web_module/1` |
  | `Composer.Helpers.repo/1`            | `Composer.Edit.Project.repo/1`        |
  | `Composer.Helpers.gen_migration/4`   | `Composer.Edit.Util.gen_migration/4`  |
  """

  @doc deprecated: "Use Composer.Edit.Project.app_module/1 instead."
  defdelegate app_module(igniter), to: Composer.Edit.Project

  @doc deprecated: "Use Composer.Edit.Project.repo/1 instead."
  defdelegate repo(igniter), to: Composer.Edit.Project

  @doc deprecated: "Use Composer.Edit.Project.app_web_module/1 instead."
  defdelegate app_web_module(igniter), to: Composer.Edit.Project

  @doc deprecated: "Use Composer.Edit.Files.update/3 instead."
  defdelegate update_file_content(igniter, path, transform), to: Composer.Edit.Files, as: :update

  @doc deprecated: "Use Composer.Edit.Files.update_checked/4 instead."
  defdelegate update_file_checked(igniter, path, transform, warning),
    to: Composer.Edit.Files,
    as: :update_checked

  @doc deprecated: "Use Composer.Edit.Files.create_unless_exists/3 instead."
  defdelegate create_unless_exists(igniter, path, contents), to: Composer.Edit.Files

  @doc deprecated: "Use Composer.Edit.Util.gen_migration/4 instead."
  defdelegate gen_migration(igniter, repo, name, opts \\ []), to: Composer.Edit.Util
end
