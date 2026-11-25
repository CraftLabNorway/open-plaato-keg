defmodule OpenPlaatoKeg.Models.BarHelperConfig do
  @moduledoc """
  Per-keg BarHelper settings, kept in their own DETS table (`:barhelper_config`).

  The BarHelper API key is a secret. It lives only here — never in `:keg_data` —
  so it cannot reach GET /api/kegs, GET /api/kegs/:id, WebSocket, MQTT or
  metrics, which all read keg data. Use `public/1` for anything sent to a client.
  """

  @table :barhelper_config

  # Unit names accepted by BarHelper's custom keg monitor ("type").
  # https://docs.barhelper.app/english/settings/custom-keg-monitor
  @units ~w(mm3 cm3 ml l kl m3 km3 cl dl krm tsk msk kkp glas kanna tsp Tbs in3 fl-oz cup pnt qt gal ft3 yd3)

  def units, do: @units

  @doc "Full settings including the API key. Internal use only."
  def get(id) do
    case :dets.lookup(@table, id) do
      [{^id, settings}] -> settings
      _ -> %{}
    end
  end

  @doc "Settings safe to return to a browser: no API key, only whether one is set."
  def public(id) do
    s = get(id)

    %{
      enabled: s[:enabled] == true,
      configured: configured?(s),
      monitor_id: s[:monitor_id] || "",
      unit: s[:unit] || "l",
      last_status: s[:last_status],
      last_error: s[:last_error],
      last_sent_at: s[:last_sent_at],
      last_attempt_at: s[:last_attempt_at]
    }
  end

  def configured?(settings), do: (settings[:api_key] || "") != ""

  def put(id, changes) when is_map(changes) do
    :dets.insert(@table, {id, Map.merge(get(id), changes)})
    :ok
  end

  def delete(id) do
    :dets.delete(@table, id)
    :ok
  end
end
