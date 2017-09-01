defmodule ETrace.CountTool do
  @moduledoc """
  Reports count type traces
  """
  alias __MODULE__
  alias ETrace.{EventCall, Probe}
  use ETrace.Tool

  defmodule Event do
    @moduledoc """
    Event generated by the CountTool
    """
    defstruct counts: []

    defimpl String.Chars, for: Event do
      def to_string(event) do
        event.counts
        |> find_max_lengths()
        |> format_count_entries()
        |> Enum.map(fn {e, count} ->
          "\t#{String.pad_trailing(Integer.to_string(count), 15)}[#{e}]"
        end)
        |> Enum.join("\n")
      end

      defp find_max_lengths(list) do
        Enum.reduce(list, {nil, []},
            fn {e, c}, {max, acc} ->
          max = max || Enum.map(e, fn _ -> 0 end)
          max = e
          |> Enum.zip(max)
          |> Enum.map(fn
            {{:_unknown, other}, m} ->
              max(m, String.length(other))
            {{key, val}, m} ->
              max(m, String.length("#{Atom.to_string(key)}:#{inspect val}"))
         end)
          {max, acc ++ [{e, c}]}
        end)
      end

      defp format_count_entries({max, list}) do
        Enum.map(list, fn({e, c}) ->
          e_as_string = max
          |> Enum.zip(e)
          |> Enum.map(fn
            {m, {:_unknown, other}} ->
              String.pad_trailing(other, m)
            {m, {key, val}} ->
              String.pad_trailing("#{Atom.to_string(key)}:#{inspect val}", m)
          end)
          |> Enum.join(", ")
          {e_as_string, c}
        end)
      end
    end
  end

  defstruct counts: %{}

  def init(opts) when is_list(opts) do
    init_state = init_tool(%CountTool{}, opts)

    # if Keyword.keyword?(:match) do
    #   raise ArgumentError, message: "must have something to match"
    # end

    case Keyword.get(opts, :match) do
      nil -> init_state
      matcher ->
        probe = Probe.new(type: :call,
                          process: get_process(init_state),
                          match_by: matcher)
        set_probes(init_state, [probe])
    end
  end

  def handle_event(event, state) do
    case event do
      %EventCall{message: message} ->
        key = message_to_tuple_list(message)
        new_count = Map.get(state.counts, key, 0) + 1
        put_in(state.counts, Map.put(state.counts, key, new_count))
      _ -> state
    end
  end

  def handle_done(state) do
    counts = state.counts
    |> Map.to_list()
    |> Enum.sort(&(elem(&1, 1) < elem(&2, 1)))

    report_event(state, %Event{
        counts: counts
    })

    state
  end

  defp message_to_tuple_list(term) when is_list(term) do
    term
    |> Enum.map(fn
      [key, val] -> {key, val}
      # [key, val] -> {key, inspect(val)}
      other -> {:_unknown, inspect(other)}
     end)
  end

end
