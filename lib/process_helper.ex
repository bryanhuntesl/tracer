defmodule Tracer.ProcessHelper do
  @moduledoc """
  Implements helper functions to find OTP process hierarchy
  """
  def ensure_pid(pid) when is_pid(pid), do: pid
  def ensure_pid(name) when is_atom(name) do
    case Process.whereis(name) do
      nil ->
        raise ArgumentError,
              message: "#{inspect name} is not a registered process"
      pid when is_pid(pid) -> pid
    end
  end

  def type(pid) do
    dict = pid
    |> ensure_pid()
    |> Process.info()
    |> Keyword.get(:dictionary)

    case dict do
      [] ->
        :regular
      _ ->
        case Keyword.get(dict, :"$initial_call") do
          {:supervisor, _, _} -> :supervisor
          {_, :init, _} -> :worker
          _ -> :regular
        end
    end
  end

  def find_children(pid) do
    pid = ensure_pid(pid)
    case type(pid) do
      :supervisor ->
        child_spec = Supervisor.which_children(pid)
        Enum.reduce(child_spec, [], fn
          {_mod, pid, _type, _params}, acc when is_pid(pid) -> acc ++ [pid]
          _, acc -> acc
        end)
      _ -> []
    end
  end

  def find_all_children(pid) do
    pid = ensure_pid(pid)
    case type(pid) do
      :supervisor ->
        find_all_supervisor_children([pid], [])
      _ -> []
    end
  end

  def find_all_supervisor_children([], acc), do: acc
  def find_all_supervisor_children([sup | sups], pids) do
    {s, p} = sup
    |> Supervisor.which_children()
    |> Enum.reduce({[], []}, fn
      {_mod, pid, :supervisor, _params}, {s, p} when is_pid(pid) ->
        {s ++ [pid], p ++ [pid]}
      {_mod, pid, _type, _params}, {s, p} when is_pid(pid) ->
        {s, p ++ [pid]}
      _, acc -> acc
    end)
    find_all_supervisor_children(sups ++ s, pids ++ p)
  end
end
