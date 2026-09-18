defmodule OpenPlaatoKeg.Models.BatchHistory do
  @moduledoc """
  Archived fermentation/keg-drain cycle records, backed by a DETS table.

  Keyed by {device_type, device_id, archived_at} so a device can accumulate
  many archived cycles over time, listed newest first. Written only via the
  explicit `/archive` endpoints (matches this codebase's existing pattern of
  explicit user actions over automatic cycle-boundary detection).
  """

  @table :batch_history

  @doc "Store `snapshot` (a string-keyed map) as a new archive entry. Returns the archive timestamp."
  def archive(device_type, device_id, snapshot) when is_map(snapshot) do
    now = System.system_time(:second)
    :dets.insert(@table, {{device_type, device_id, now}, snapshot})
    {:ok, now}
  end

  @doc "List archived records for a device, newest first, each with an `\"archived_at\"` key added."
  def list(device_type, device_id) do
    matchspec = [
      {
        {{device_type, device_id, :"$1"}, :"$2"},
        [],
        [{{:"$1", :"$2"}}]
      }
    ]

    case :dets.select(@table, matchspec) do
      {:error, _} ->
        []

      results ->
        results
        |> Enum.sort_by(fn {ts, _} -> ts end, :desc)
        |> Enum.map(fn {ts, snapshot} -> Map.put(snapshot, "archived_at", ts) end)
    end
  end

  @doc "Timestamp of the most recent archive for a device, or `nil` if none exist yet."
  def most_recent_timestamp(device_type, device_id) do
    case list(device_type, device_id) do
      [%{"archived_at" => ts} | _] -> ts
      [] -> nil
    end
  end
end
