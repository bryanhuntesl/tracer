defmodule ETrace.Probe do
  @moduledoc """
  Probe manages a single probe
  """

  alias __MODULE__
  alias ETrace.Clause

  @valid_types [:call, :process, :gc, :sched, :send, :receive]
  @flag_map %{
    call: :call,
    process: :procs,
    sched: :running,
    send: :send,
    receive: :receive
  }

  @new_options [
    :type, :in_process, :with_fun, :filter_by, :match_by
  ]

  defstruct type: nil,
            process_list: [],
            clauses: [],
            enabled?: true,
            flags: [:arity, :timestamp]

  def new(opts) when is_list(opts) do
    if Keyword.fetch(opts, :type) != :error do
      Enum.reduce(opts, %Probe{}, fn {field, val}, probe ->
        cond do
          is_tuple(probe) and elem(probe, 0) == :error -> probe
          !Enum.member?(@new_options, field) ->
            {:error, "#{field} not a valid option"}
          true ->
            apply(__MODULE__, field, [probe, val])
        end
      end)
    else
      {:error, :missing_type}
    end
  end

  # Generate functions Probe.call, Probe.process, ...
  @valid_types |> Enum.each(fn type ->
    def unquote(type)(opts) when is_list(opts) do
      Probe.new([{:type, unquote(type)} | opts])
    end
  end)

  def get_type(probe) do
    probe.type
  end

  def process_list(probe) do
    probe.process_list
  end

  def process_list(probe, procs) do
    put_in(probe.process_list, Enum.uniq(procs))
  end

  def add_process(probe, procs) when is_list(procs) do
    put_in(probe.process_list,
      probe.process_list
        |> Enum.concat(procs)
        |> Enum.uniq
    )
  end
  def add_process(probe, proc) do
    put_in(probe.process_list, Enum.uniq([proc | probe.process_list]))
  end

  def remove_process(probe, procs) when is_list(procs) do
    put_in(probe.process_list, probe.process_list -- procs)
  end
  def remove_process(probe, proc) do
    remove_process(probe, [proc])
  end

  def add_clauses(probe, clauses) when is_list(clauses) do
    # if Enum.any?(clauses, fn
    #   %Clause{type: ^probe.type} -> false
    #   %Clause{} -> false
    #   _ -> true
    #   end) do
    #   {:error, :not_a_clause}
    # else
    #   put_in(probe.clauses, Enum.concat(probe.clauses, clauses))
    # end

    with [] <- valid_clauses?(clauses, Probe.get_type(probe)) do
      put_in(probe.clauses, Enum.concat(probe.clauses, clauses))
    else
      error_list -> {:error, error_list}
    end
  end
  def add_clauses(probe, clause) do
    add_clauses(probe, [clause])
  end

  defp valid_clauses?(clauses, expected_type) do
    Enum.reduce(clauses, [], fn
      %Clause{type: ^expected_type}, acc -> acc
      %Clause{} = c, acc -> [{:invalid_clause_type, c} | acc]
      c, acc -> [{:not_a_clause, c} | acc]
    end)
  end

  def remove_clauses(probe, clauses) when is_list(clauses) do
    put_in(probe.clauses, probe.clauses -- clauses)
  end
  def remove_clauses(probe, clause) do
    remove_clauses(probe, [clause])
  end

  def clauses(probe) do
    probe.clauses
  end

  def enable(probe) do
    put_in(probe.enabled?, true)
  end

  def disable(probe) do
    put_in(probe.enabled?, false)
  end

  def enabled?(probe) do
    probe.enabled?
  end

  def valid?(probe) do
    with :ok <- validate_process_list(probe) do
      true
    end
  end

  def apply(probe, flags \\ []) do
    with true <- valid?(probe) do
      # Apply trace commands
      Enum.each(probe.process_list, fn p ->
        :erlang.trace(p, probe.enabled?, flags ++ flags(probe))
      end)
      # Apply trace_pattern commands
      Enum.each(probe.clauses, fn c -> Clause.apply(c, probe.enabled?) end)
      probe
    end
  end

  def get_trace_cmds(probe, flags \\ []) do
    with true <- valid?(probe) do
      probe_cmds = Enum.reduce(probe.clauses, [], fn c, acc ->
        if probe.enabled?, do: [Clause.get_trace_cmd(c) | acc], else: acc
      end)

      probe.process_list
      |> Enum.reduce(probe_cmds, fn p, acc ->
        if probe.enabled? do
          trace_cmd = [
            fun: &:erlang.trace/3,
            pid_port_spec: p,
            how: true,
            flag_list: flags ++ flags(probe)
          ]
          [trace_cmd | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()
    else
      error -> raise RuntimeError, message: "invalid probe #{inspect error}"
    end
  end

  [:arity, :timestamp] |> Enum.each(fn flag ->
    def unquote(flag)(probe, enable) when is_boolean(enable) do
      flag(probe, unquote(flag), enable)
    end
  end)

  defp flag(probe, flag, true) do
    put_in(probe.flags, Enum.uniq([flag | probe.flags]))
  end
  defp flag(probe, flag, false) do
    put_in(probe.flags, probe.flags -- [flag])
  end

  defp flags(probe) do
    [Map.get(@flag_map, probe.type) | probe.flags]
  end

  defp valid_type?(type) do
    if Enum.member?(@valid_types, type) do
      {:ok, type}
    else
      {:error, :invalid_type}
    end
  end

  defp validate_process_list(probe) do
    if Enum.empty?(probe.process_list) do
      {:error, :missing_processes}
    else
      :ok
    end
  end

  # Helper Functions
  def type(probe, type) do
    with {:ok, type} <- valid_type?(type) do
      put_in(probe.type, type)
    end
  end

  def in_process(probe, process) do
    add_process(probe, process)
  end

  def with_fun(probe, fun) when is_function(fun) do
    case probe.clauses do
      [] ->
        put_in(probe.clauses, [Clause.new() |> Clause.put_fun(fun)])
      [clause | rest] ->
        put_in(probe.clauses, [Clause.put_fun(clause, fun) | rest])
    end
  end

  def with_fun(probe, {m}), do: with_fun(probe, {m, :_, :_})
  def with_fun(probe, {m, f}), do: with_fun(probe, {m, f, :_})
  def with_fun(probe, {m, f, a}) do
    case probe.clauses do
      [] ->
        put_in(probe.clauses, [Clause.new() |> Clause.put_mfa(m, f, a)])
      [clause | rest] ->
        put_in(probe.clauses, [Clause.put_mfa(clause, m, f, a) | rest])
    end
  end

  def filter_by(probe, matcher) do
    case probe.clauses do
      [] ->
        put_in(probe.clauses, [Clause.new() |> Clause.add_matcher(matcher)])
      [clause | rest] ->
        put_in(probe.clauses, [Clause.add_matcher(clause, matcher) | rest])
    end
  end

  def match_by(probe, matcher) do
    case probe.clauses do
      [] ->
        {m, f, a} = Map.get(matcher, :mfa)
        clause =
          Clause.new()
          |> Clause.add_matcher(Map.get(matcher, :ms))
          |> Clause.put_mfa(m, f, a)
          |> Clause.set_flags(Map.get(matcher, :flags, []))
          |> Clause.set_desc(Map.get(matcher, :desc, "unavailable"))
        probe
        |> Map.put(:clauses, [clause])
      [_clause | _rest] ->
        {:error, :clause_already_configured}
    end
  end

end
