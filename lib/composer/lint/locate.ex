defmodule Composer.Lint.Locate do
  @moduledoc false
  # Turns an anchor (`Composer.Error.anchor/1`) into a place: a file, a
  # range in it (or nil) and related places. Chapter files are indexed with
  # `Composer.Recipe.Locator` once each, and step sources parsed once each;
  # `place/3` returns the updated struct holding those caches.

  alias Composer.{Cookbook, Ref, Resolver}
  alias Composer.Lint.Diagnostic
  alias Composer.Recipe.Locator

  defstruct cookbooks: %{}, recipes: %{}, resolver: nil, root: nil, steps: nil, files: %{}

  @type t :: %__MODULE__{}
  @type place :: {Path.t() | nil, Diagnostic.range() | nil, [Diagnostic.related()]}

  @doc """
  `cookbooks` are every cookbook references resolve against; `recipes` the
  loaded recipes (to follow `{:use, ...}` entries through aliases).
  `:root` is the project root, where step tests are looked for.
  """
  def new(cookbooks, recipes, opts \\ []) do
    %__MODULE__{
      cookbooks: Map.new(cookbooks, &{&1.name, &1}),
      recipes: Map.new(recipes, &{&1.ref, &1}),
      resolver: Resolver.index(cookbooks),
      root: opts[:root] || File.cwd!()
    }
  end

  @doc "Places `anchor`; `context` is the recipe being checked, or nil."
  @spec place(t(), Composer.Error.anchor() | :unknown, String.t() | nil) :: {place(), t()}
  def place(locate, anchor, context)

  def place(locate, {:ref, origin, written}, context),
    do: in_recipe(locate, origin || context, {:ref, written})

  def place(locate, {:entry, ref, entry}, _context), do: in_recipe(locate, ref, {:entry, entry})

  def place(locate, {:recipe_key, ref, {:if, flag}}, _context),
    do: in_recipe(locate, ref, {:if, flag})

  def place(locate, {:recipe_key, ref, key}, _context), do: in_recipe(locate, ref, {:key, key})
  def place(locate, {:alias, ref, name}, _context), do: in_recipe(locate, ref, {:alias, name})
  def place(locate, {:recipe, ref}, _context), do: in_recipe(locate, ref, :recipe)

  def place(locate, {:recipe_name, path, name}, _context) do
    {index, locate} = index(locate, path)

    case index && Locator.recipe_keys(index, to_string(name)) do
      [_ | _] = keys ->
        {first, [primary | _]} = Enum.split(keys, -1)
        related = for range <- first, do: related(path, range, "#{name} is first defined here")
        {{path, primary, related}, locate}

      _ ->
        {{path, Locator.first_line(), []}, locate}
    end
  end

  def place(locate, {:recipe_named, cookbook, name}, context) do
    case recipe_named(locate, cookbook, name) do
      nil -> place(locate, nil, context)
      ref -> in_recipe(locate, ref, :recipe)
    end
  end

  def place(locate, {:cycle, chain}, _context) do
    hops = Enum.chunk_every(chain, 2, 1, :discard)

    {places, locate} =
      Enum.map_reduce(hops, locate, fn [from, to], locate ->
        {{file, range, _}, locate} = use_of(locate, from, to)
        {{file, range, "#{from} includes #{to}"}, locate}
      end)

    {earlier, [{file, range, _message}]} = Enum.split(places, -1)
    {{file, range, Enum.map(earlier, fn {f, r, m} -> related(f, r, m) end)}, locate}
  end

  def place(locate, {:install, package, installs}, _context) do
    {places, {locate, _seen}} =
      Enum.map_reduce(installs, {locate, %{}}, fn {origin, label}, {locate, seen} ->
        n = Map.get(seen, origin, 0)
        {place, locate} = install(locate, origin, package, n)
        {{place, label}, {locate, Map.put(seen, origin, n + 1)}}
      end)

    case Enum.filter(places, fn {{file, _, _}, _} -> file end) do
      [] ->
        {{nil, nil, []}, locate}

      [{{file, range, _}, _label} | rest] ->
        related = for {{f, r, _}, label} <- rest, do: related(f, r, "also installed as #{label}")
        {{file, range, related}, locate}
    end
  end

  def place(locate, {:file, path}, _context), do: {{path, nil, []}, locate}
  def place(locate, {:file, path, nil}, _context), do: {{path, nil, []}, locate}

  def place(locate, {:file, path, line}, _context) do
    {lines, locate} = lines(locate, path)

    range =
      case lines && line <= tuple_size(lines) && elem(lines, line - 1) do
        text when is_binary(text) -> {{line, 1}, {line, String.length(text) + 1}}
        _ -> {{line, 1}, {line, 1}}
      end

    {{path, range, []}, locate}
  end

  def place(locate, {:step, ref}, _context), do: step(locate, ref, nil)
  def place(locate, {:step, ref, detail}, _context), do: step(locate, ref, detail)
  def place(locate, _nil_or_unknown, _context), do: {{nil, nil, []}, locate}

  # -- recipes ----------------------------------------------------------------

  defp in_recipe(locate, nil, _target), do: {{nil, nil, []}, locate}

  defp in_recipe(locate, ref, target) do
    case recipe_file(locate, ref) do
      nil ->
        {{nil, nil, []}, locate}

      {path, name} ->
        {index, locate} = index(locate, path)
        range = if index, do: Locator.locate(index, name, target), else: Locator.first_line()
        {{path, range, []}, locate}
    end
  end

  @doc "The reference of a recipe named `name` in any chapter of `cookbook`, or nil."
  def recipe_named(locate, cookbook, name) do
    with %Cookbook{} = book <- locate.cookbooks[cookbook],
         id when is_binary(id) <- Enum.find(Cookbook.recipes(book), &(Path.basename(&1) == name)) do
      Ref.id(cookbook, id)
    end
  end

  @doc "The chapter file of recipe `ref`, or nil."
  def recipe_path(locate, ref) do
    case recipe_file(locate, ref) do
      {path, _name} -> path
      nil -> nil
    end
  end

  # The chapter file and recipe name of a recipe reference.
  defp recipe_file(locate, ref) do
    case locate.recipes[ref] do
      %{path: path, name: name} ->
        {path, name}

      nil ->
        with {:ok, %Ref{cookbook: cookbook, path: id}} <- Ref.parse(ref),
             %Cookbook{} = book <- locate.cookbooks[cookbook],
             [chapter, name] <- String.split(id, "/"),
             path when is_binary(path) <- Cookbook.chapter_path(book, chapter) do
          {path, name}
        else
          _ -> nil
        end
    end
  end

  # The {:use, ...} in recipe `from` that includes recipe `to`.
  defp use_of(locate, from, to) do
    written =
      case locate.recipes[from] do
        nil ->
          nil

        recipe ->
          Enum.find_value(Resolver.included(locate.resolver, recipe), fn
            {written, {:ok, ^to}} -> written
            _ -> nil
          end)
      end

    match = written || fn s -> s == to or String.ends_with?(to, [":" <> s, "/" <> s]) end
    in_recipe(locate, from, {:ref, match})
  end

  # The `n`th reference to `package` in recipe `origin`.
  defp install(locate, nil, _package, _n), do: {{nil, nil, []}, locate}

  defp install(locate, origin, package, n) do
    case recipe_file(locate, origin) do
      nil ->
        {{nil, nil, []}, locate}

      {path, name} ->
        {index, locate} = index(locate, path)
        names? = &names_package?(&1, package)

        range =
          cond do
            index == nil -> Locator.first_line()
            range = Enum.at(Locator.refs(index, name, names?), n) -> range
            true -> Locator.locate(index, name, {:ref, names?})
          end

        {{path, range, []}, locate}
    end
  end

  defp names_package?(string, package) do
    case Ref.parse(string) do
      {:ok, %Ref{cookbook: cookbook, path: ^package}} when cookbook in [nil, "hex"] -> true
      _ -> false
    end
  end

  # -- files ------------------------------------------------------------------

  defp index(locate, path) do
    {entry, locate} = file(locate, path)
    {entry.index, locate}
  end

  defp lines(locate, path) do
    {entry, locate} = file(locate, path)
    {entry.lines, locate}
  end

  defp file(locate, path) do
    case locate.files do
      %{^path => entry} ->
        {entry, locate}

      _ ->
        entry =
          case File.read(path) do
            {:ok, source} ->
              index =
                case Locator.index(source, path) do
                  {:ok, index} -> index
                  {:error, _} -> nil
                end

              %{index: index, lines: source |> String.split(~r/\r?\n/) |> List.to_tuple()}

            {:error, _} ->
              %{index: nil, lines: nil}
          end

        {entry, %{locate | files: Map.put(locate.files, path, entry)}}
    end
  end

  defp related(file, range, message),
    do: %{file: file && Path.expand(file), range: range, message: message}

  # -- steps ------------------------------------------------------------------

  defp step(locate, ref, detail) do
    locate = steps(locate)

    with %{module: module} <- locate.steps[ref],
         source when is_binary(source) <- source(module),
         {{:ok, ast, lines}, locate} <- step_source(locate, source) do
      {range, related} = step_range(ast, lines, detail, locate.root)
      {{source, range, related}, locate}
    else
      {_error, %__MODULE__{} = locate} -> {{nil, nil, []}, locate}
      _ -> {{nil, nil, []}, locate}
    end
  end

  @doc """
  The range of the `use Composer.Step` call in the step source at `path`,
  or `nil` when it does not parse or has none. Goto-definition uses it.
  """
  @spec step_use(Path.t()) :: Diagnostic.range() | nil
  def step_use(path) do
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source, [file: path] ++ Locator.parse_opts()),
         use when use != nil <- find_use(ast) do
      use_range(use)
    else
      _ -> nil
    end
  end

  @doc "The existing source file of a compiled module, or `nil`."
  @spec source(module()) :: Path.t() | nil
  def source(module) do
    case module.module_info(:compile)[:source] do
      nil -> nil
      source -> if File.regular?(to_string(source)), do: to_string(source)
    end
  end

  defp steps(%{steps: nil} = locate) do
    steps =
      for {_name, %Cookbook{kind: :code} = book} <- locate.cookbooks,
          meta <- Cookbook.steps(book),
          into: %{},
          do: {meta.ref, meta}

    %{locate | steps: steps}
  end

  defp steps(locate), do: locate

  defp step_source(locate, path) do
    key = {:step, path}

    case locate.files do
      %{^key => parsed} ->
        {parsed, locate}

      _ ->
        parsed =
          with {:ok, source} <- File.read(path),
               {:ok, ast} <- Code.string_to_quoted(source, [file: path] ++ Locator.parse_opts()) do
            {:ok, ast, source |> String.split(~r/\r?\n/) |> List.to_tuple()}
          end

        {parsed, %{locate | files: Map.put(locate.files, key, parsed)}}
    end
  end

  # The `use Composer.Step` call, or a literal in its options or in a
  # template/1 call; the use line when the literal is not found.
  defp step_range(ast, lines, detail, root) do
    use = find_use(ast)
    use_range = use && use_range(use)
    ctx = %{lines: lines}

    case detail do
      {:template, path} ->
        {template_literal(ast, path, ctx) || use_range, []}

      {:requires, ref} ->
        {(use && requires_literal(use, ref, ctx)) || use_range, []}

      {:test, path} ->
        test = Path.expand(path, root)
        {use_range, [related(test, nil, "expected test file #{path}")]}

      nil ->
        {use_range, []}
    end
  end

  defp find_use(ast) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:use, _, [{:__aliases__, _, [:Composer, :Step]} | _]} = node, nil -> {node, node}
        node, found -> {node, found}
      end)

    found
  end

  defp use_range({:use, meta, [{:__aliases__, alias_meta, segments} | _]}) do
    {line, column} = {meta[:line], meta[:column]}

    case alias_meta[:last] do
      last when is_list(last) ->
        {{line, column},
         {last[:line], last[:column] + String.length(to_string(List.last(segments)))}}

      _ ->
        {{line, column}, {line, column + String.length("use Composer.Step")}}
    end
  end

  defp template_literal(ast, path, ctx) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:template, _, [{:__block__, _, [^path]} = literal]} = node, nil ->
          {node, Locator.string_range(ctx, literal)}

        node, found ->
          {node, found}
      end)

    found
  end

  defp requires_literal({:use, _, [_alias, {:__block__, _, [opts]}]}, ref, ctx)
       when is_list(opts),
       do: requires_literal({:use, [], [nil, opts]}, ref, ctx)

  defp requires_literal({:use, _, [_alias, opts]}, ref, ctx) when is_list(opts) do
    Enum.find_value(opts, fn
      {{:__block__, key_meta, [:requires]}, value} ->
        literal =
          case value do
            {:__block__, _, [list]} when is_list(list) ->
              Enum.find_value(list, fn
                {:__block__, _, [^ref]} = literal -> Locator.string_range(ctx, literal)
                _ -> nil
              end)

            _ ->
              nil
          end

        {line, column} = {key_meta[:line], key_meta[:column]}
        literal || {{line, column}, {line, column + String.length("requires:")}}

      _ ->
        nil
    end)
  end

  defp requires_literal(_use, _ref, _ctx), do: nil
end
