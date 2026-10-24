import Config

if config_env() == :dev do
  config :git_ops,
    mix_project: Mix.Project.get!(),
    types: [tidbit: [hidden?: true], important: [header: "Important Changes"]],
    github_handle_lookup?: false,
    version_tag_prefix: "v",
    manage_mix_version?: true,
    manage_readme_version: true,
    # The composer_new archive (installer/) is released in lockstep.
    managed_files: [{"installer/mix.exs", :mix}]
end
