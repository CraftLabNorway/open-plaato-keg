defmodule OpenPlaatoKeg.AlertEngine do
  @moduledoc """
  Periodically evaluates keg/airlock devices for the four Web Push alert
  conditions (keg empty, leak detected, temp out of range, fermentation
  stalled) and sends a push notification on an ok -> alert transition, so a
  standing condition doesn't re-notify on every tick.

  Leak detection needs the previous tick's reading; that's kept in this
  GenServer's own (in-memory, non-persisted) state — losing it across a
  restart just means one leak check is skipped, which is an acceptable
  trade-off for not needing another DETS table for transient data.
  """
  use GenServer
  require Logger

  alias OpenPlaatoKeg.Models.AirlockData
  alias OpenPlaatoKeg.Models.AlertState
  alias OpenPlaatoKeg.Models.DataLog
  alias OpenPlaatoKeg.Models.KegData
  alias OpenPlaatoKeg.Models.PushSubscription

  @tick_interval_ms 5 * 60 * 1000
  @default_low_keg_threshold_percent 10.0
  @leak_drop_fraction 0.15
  @stall_lookback_seconds 12 * 3600
  @stall_min_bubbles_active 1.0
  @stall_max_bubbles_stalled 0.5

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{last_keg_amount: %{}}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Process.send_after(self(), :tick, @tick_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state = evaluate_all(state)
    Process.send_after(self(), :tick, @tick_interval_ms)
    {:noreply, new_state}
  end

  defp evaluate_all(state) do
    last_keg_amount =
      Enum.reduce(KegData.devices(), state.last_keg_amount, fn id, acc ->
        evaluate_keg(id, acc)
      end)

    Enum.each(AirlockData.devices(), &evaluate_airlock/1)

    %{state | last_keg_amount: last_keg_amount}
  end

  defp evaluate_keg(id, last_keg_amount) do
    data = KegData.get(id)
    percent = parse_float(data[:percent_of_beer_left])
    threshold = parse_float(data[:my_low_keg_threshold_percent]) || @default_low_keg_threshold_percent
    keg_empty? = is_number(percent) and percent <= threshold

    maybe_notify(:keg, id, :keg_empty, keg_empty?, "Keg running low", fn ->
      "#{label_for_keg(data)} is at #{round(percent)}% left."
    end)

    amount = parse_float(data[:amount_left])
    is_pouring = truthy_pour?(data[:is_pouring])
    prev_amount = Map.get(last_keg_amount, id)

    leak? =
      is_number(amount) and is_number(prev_amount) and prev_amount > 0 and not is_pouring and
        (prev_amount - amount) / prev_amount >= @leak_drop_fraction

    maybe_notify(:keg, id, :leak_detected, leak?, "Possible keg leak", fn ->
      "#{label_for_keg(data)} lost weight quickly without a pour — check for a leak."
    end)

    if is_number(amount), do: Map.put(last_keg_amount, id, amount), else: last_keg_amount
  end

  defp evaluate_airlock(id) do
    data = AirlockData.get(id)
    temp = parse_float(data[:temperature])
    min_temp = parse_float(data[:my_temp_alert_min])
    max_temp = parse_float(data[:my_temp_alert_max])

    out_of_range? =
      is_number(temp) and
        ((is_number(min_temp) and temp < min_temp) or (is_number(max_temp) and temp > max_temp))

    maybe_notify(:airlock, id, :temp_out_of_range, out_of_range?, "Temperature out of range", fn ->
      "#{label_for_airlock(data)} is at #{temp}°C, outside your configured range."
    end)

    maybe_notify(
      :airlock,
      id,
      :fermentation_stalled,
      fermentation_stalled?(id),
      "Fermentation may have stalled",
      fn -> "#{label_for_airlock(data)} has shown little bubble activity for the last 12 hours." end
    )
  end

  defp fermentation_stalled?(id) do
    now = System.system_time(:second)
    entries = DataLog.get(:airlock, id, now - @stall_lookback_seconds, now)

    bubble_entries =
      entries
      |> Enum.map(&parse_float(&1["bubbles_per_min"]))
      |> Enum.reject(&is_nil/1)

    if length(bubble_entries) < 4 do
      false
    else
      {earlier, recent} = Enum.split(bubble_entries, div(length(bubble_entries), 2))
      earlier_max = Enum.max(earlier)
      recent_max = Enum.max(recent)

      earlier_max >= @stall_min_bubbles_active and recent_max <= @stall_max_bubbles_stalled
    end
  end

  defp maybe_notify(device_type, device_id, alert_type, is_alert_now?, title, body_fn) do
    new_status = if is_alert_now?, do: :alert, else: :ok
    prev_status = AlertState.get(device_type, device_id, alert_type) || :ok

    if new_status != prev_status do
      AlertState.put(device_type, device_id, alert_type, new_status)

      if new_status == :alert do
        notify(device_type, device_id, alert_type, title, body_fn.())
      end
    end
  end

  defp notify(device_type, device_id, alert_type, title, body) do
    device_type
    |> PushSubscription.for_device(device_id)
    |> Enum.filter(fn {_endpoint, sub} -> to_string(alert_type) in sub.alerts end)
    |> Enum.each(fn {endpoint, sub} ->
      send_push(device_type, device_id, endpoint, sub, title, body, alert_type)
    end)
  end

  defp send_push(device_type, device_id, endpoint, sub, title, body, alert_type) do
    subscription = %ExNudge.Subscription{
      endpoint: endpoint,
      keys: %{p256dh: sub.keys["p256dh"] || sub.keys[:p256dh], auth: sub.keys["auth"] || sub.keys[:auth]}
    }

    payload =
      Poison.encode!(%{
        title: title,
        body: body,
        alert_type: to_string(alert_type),
        device_type: to_string(device_type),
        device_id: device_id
      })

    case ExNudge.send_notification(subscription, payload, ttl: 3600) do
      {:ok, _resp} ->
        Logger.info("AlertEngine: sent #{alert_type} push for #{device_type} #{device_id}")

      {:error, :subscription_expired} ->
        Logger.info("AlertEngine: subscription expired, removing (#{device_type} #{device_id})")
        PushSubscription.unsubscribe(device_type, device_id, endpoint)

      {:error, reason} ->
        Logger.warning("AlertEngine: push failed for #{device_type} #{device_id}: #{inspect(reason)}")
    end
  end

  defp truthy_pour?(v) when v in [nil, "0", 0, 255, "255"], do: false
  defp truthy_pour?(_), do: true

  defp label_for_keg(data), do: data[:my_label] || data[:my_beer_style] || "Your keg"
  defp label_for_airlock(data), do: data[:label] || "Your airlock"

  defp parse_float(nil), do: nil
  defp parse_float(v) when is_number(v), do: v * 1.0
  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end
  defp parse_float(_), do: nil
end
