defmodule Composer.Step.Meta do
  @moduledoc """
  A step's declared metadata, returned by its `__composer_step__/0`.

  `id` is the step's path under its cookbook's `steps/` directory
  (`"ash/postgres"`), and `ref` the full reference (`"composer_lab:ash/postgres"`).
  """

  defstruct [
    :id,
    :ref,
    :cookbook,
    :module,
    :summary,
    :action,
    :phase,
    :stability,
    :author,
    :license,
    :homepage,
    frameworks: [],
    capability: [],
    tags: [],
    requires: [],
    provides: [],
    conflicts: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          ref: String.t(),
          cookbook: String.t(),
          module: module(),
          summary: String.t() | nil,
          action: atom() | nil,
          phase: atom() | nil,
          stability: atom() | nil,
          author: String.t() | nil,
          license: String.t() | nil,
          homepage: String.t() | nil,
          frameworks: [atom()],
          capability: [atom()],
          tags: [String.t()],
          requires: [Composer.Facets.requirement()],
          provides: [atom()],
          conflicts: [atom()]
        }

  @doc """
  Returns the metadata as plain data with string keys, for the manifest and
  `--json` output. `requires` tuples become maps.
  """
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = meta) do
    %{
      "id" => meta.id,
      "ref" => meta.ref,
      "summary" => meta.summary,
      "action" => atom(meta.action),
      "phase" => atom(meta.phase),
      "stability" => atom(meta.stability),
      "frameworks" => Enum.map(meta.frameworks, &Atom.to_string/1),
      "capability" => Enum.map(meta.capability, &Atom.to_string/1),
      "tags" => meta.tags,
      "requires" => Enum.map(meta.requires, &requirement/1),
      "provides" => Enum.map(meta.provides, &Atom.to_string/1),
      "conflicts" => Enum.map(meta.conflicts, &Atom.to_string/1),
      "author" => meta.author,
      "license" => meta.license,
      "homepage" => meta.homepage
    }
  end

  @doc """
  The metadata shown for a step (by `mix composer.step.show` and the
  language server's hover), as `{label, text}` rows. Empty values are left
  out.
  """
  @spec rows(t()) :: [{String.t(), String.t()}]
  def rows(%__MODULE__{} = meta) do
    [
      {"action", meta.action},
      {"frameworks", meta.frameworks},
      {"capability", meta.capability},
      {"phase", meta.phase},
      {"stability", meta.stability},
      {"tags", meta.tags},
      {"requires", Enum.map(meta.requires, &format_requirement/1)},
      {"provides", meta.provides},
      {"conflicts", meta.conflicts},
      {"author", meta.author},
      {"license", meta.license},
      {"homepage", meta.homepage},
      {"module", inspect(meta.module)}
    ]
    |> Enum.reject(fn {_label, value} -> value in [nil, []] end)
    |> Enum.map(fn {label, value} -> {label, format(value)} end)
  end

  @doc "What a `hex:` reference to `package` does, for display."
  @spec hex_note(String.t()) :: String.t()
  def hex_note(package) do
    """
    hex:#{package} - the Hex package #{package}

    Added to mix.exs and fetched before the run, then its own installer
    (mix #{package}.install) runs if it ships one. No cookbook has a
    step named #{inspect(package)}.
    """
  end

  defp format(values) when is_list(values), do: Enum.map_join(values, ", ", &to_string/1)
  defp format(value), do: to_string(value)

  @doc "Formats a `requires` entry for display."
  @spec format_requirement(Composer.Facets.requirement()) :: String.t()
  def format_requirement(ref) when is_binary(ref), do: ref
  def format_requirement({:executable, name}), do: "executable #{name}"
  def format_requirement({:package, name, req}), do: "package #{name} #{req}"

  defp requirement(ref) when is_binary(ref), do: %{"step" => ref}
  defp requirement({:executable, name}), do: %{"executable" => name}

  defp requirement({:package, name, req}),
    do: %{"package" => Atom.to_string(name), "requirement" => req}

  defp atom(nil), do: nil
  defp atom(atom), do: Atom.to_string(atom)
end
