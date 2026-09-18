defmodule OpenPlaatoKeg.Models.AlertState do
  @moduledoc """
  Last known ok/alert status per {device_type, device_id, alert_type}, backed
  by a DETS table. Used by `OpenPlaatoKeg.AlertEngine` to only push a
  notification on an ok -> alert transition, not on every tick a condition
  stays true.
  """

  @table :alert_state

  @doc "Returns `:ok`, `:alert`, or `nil` if never evaluated before."
  def get(device_type, device_id, alert_type) do
    case :dets.lookup(@table, {device_type, device_id, alert_type}) do
      [{_, status}] -> status
      [] -> nil
    end
  end

  def put(device_type, device_id, alert_type, status) when status in [:ok, :alert] do
    :dets.insert(@table, {{device_type, device_id, alert_type}, status})
    :ok
  end
end
