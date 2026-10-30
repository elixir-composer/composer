defmodule Composer.Edit do
  @moduledoc """
  Everything a step uses to change the target app.

    * `Composer.Edit.Files` - change file content: `update/3`,
      `update_checked/4`, `create_unless_exists/3`, and the idempotent
      `ensure_line/4`, `ensure_block/4` and `replace/5`
    * `Composer.Edit.Project` - project-level names and files in the target
      app: `app_module/1`, `app_web_module/1`, `repo/1`, `gitignore/3`
    * `Composer.Edit.Util` - other conveniences: `gen_migration/4`

  Steps usually alias what they use:

      alias Composer.Edit.{Files, Project}

  This is not `Composer.Editor`, which opens files in `$EDITOR`.
  """
end
