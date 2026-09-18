defmodule OpenPlaatoKeg.Models.PushSubscription do
  @moduledoc """
  Web Push subscriptions (browser endpoint + keys), backed by a DETS table.

  Keyed by {device_type, device_id, endpoint} so a device can have several
  subscribed browsers/devices, and one browser can subscribe to several
  devices independently.
  """

  @table :push_subscriptions

  @doc """
  Store a subscription for `device_type` (`:keg` or `:airlock`) and `device_id`.
  `alerts` is a list of alert-type strings this subscription wants
  (e.g. `["keg_empty", "leak_detected"]`).
  """
  def subscribe(device_type, device_id, endpoint, keys, alerts)
      when is_map(keys) and is_list(alerts) do
    :dets.insert(@table, {{device_type, device_id, endpoint}, %{keys: keys, alerts: alerts}})
    :ok
  end

  def unsubscribe(device_type, device_id, endpoint) do
    :dets.delete(@table, {device_type, device_id, endpoint})
    :ok
  end

  @doc "List `{endpoint, %{keys:, alerts:}}` subscriptions for a device."
  def for_device(device_type, device_id) do
    matchspec = [
      {
        {{device_type, device_id, :"$1"}, :"$2"},
        [],
        [{{:"$1", :"$2"}}]
      }
    ]

    case :dets.select(@table, matchspec) do
      {:error, _} -> []
      results -> results
    end
  end
end
