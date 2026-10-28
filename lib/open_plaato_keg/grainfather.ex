defmodule OpenPlaatoKeg.Grainfather do
  @moduledoc """
  Sends airlock fermentation data to the Grainfather community web app.
  POST at most every 15 minutes (API returns 429 if called more often).
  """
  require Logger
  alias OpenPlaatoKeg.GravityEstimate
  alias OpenPlaatoKeg.Models.AirlockData

  @throttle_minutes 15

  def maybe_send(airlock_id, temperature, bubbles_per_min) do
    airlock = AirlockData.get(airlock_id)

    enabled? =
      case airlock[:grainfather_enabled] do
        "true" -> true
        true -> true
        _ -> false
      end

    url = airlock[:grainfather_url] |> to_string() |> String.trim()

    if enabled? and url != "" do
      if throttle_ok?(airlock) do
        do_send(airlock_id, airlock, url, temperature, bubbles_per_min)
      else
        :throttled
      end
    else
      :skip
    end
  end

  @doc """
  SG to send: the bubble-based estimate when `grainfather_sg_mode` is
  "estimated" and OG + batch volume are set, otherwise the manual value.
  The estimate is also stored as `grainfather_estimated_sg` for the UI.
  """
  def current_sg(airlock_id, airlock) do
    manual = parse_specific_gravity(airlock[:grainfather_specific_gravity])

    if airlock[:grainfather_sg_mode] == "estimated" do
      case estimated_sg(airlock) do
        nil ->
          manual

        est ->
          AirlockData.publish(airlock_id, [{:grainfather_estimated_sg, to_string(est)}])
          est
      end
    else
      manual
    end
  end

  def estimated_sg(airlock) do
    og = parse_number(airlock[:grainfather_og])
    volume = parse_number(airlock[:grainfather_batch_volume])
    bubble_ml = parse_number(airlock[:grainfather_bubble_ml]) || GravityEstimate.default_bubble_ml()
    GravityEstimate.estimate(og, volume, bubbles_since_start(airlock), bubble_ml)
  end

  @doc "Bubbles counted since the batch baseline was set."
  def bubbles_since_start(airlock) do
    total = parse_number(airlock[:total_bubble_count]) || 0
    baseline = parse_number(airlock[:grainfather_bubble_baseline]) || 0
    # Lifetime total should never go backwards; if it did, count from zero.
    if total >= baseline, do: total - baseline, else: total
  end

  defp throttle_ok?(airlock) do
    case airlock[:grainfather_last_sent_at] do
      nil -> true
      ts when is_binary(ts) ->
        case Integer.parse(ts) do
          {ms, _} -> now_ms() - ms >= @throttle_minutes * 60 * 1000
          :error -> true
        end
      _ -> true
    end
  end

  defp now_ms do
    System.system_time(:millisecond)
  end

  defp do_send(airlock_id, airlock, url, temperature, bubbles_per_min) do
    bubbles_per_min = bubbles_per_min || airlock[:bubbles_per_min]
    unit = airlock[:grainfather_unit] || "celsius"
    sg = current_sg(airlock_id, airlock)

    temp_value =
      case temperature do
        nil -> nil
        t when is_binary(t) ->
          case Float.parse(t) do
            {f, _} -> temp_for_unit(f, unit)
            :error -> nil
          end
        t when is_number(t) -> temp_for_unit(t, unit)
      end

    # API requires temp and sg
    if temp_value == nil do
      Logger.debug("Grainfather: skip (no temperature)")
      :skip
    else
      body = %{
        "sg" => sg,
        "temp" => temp_value,
        "temp_unit" => (if unit == "fahrenheit", do: "°F", else: "°C")
      }

      body =
        case bubbles_per_min do
          nil -> body
          b when is_binary(b) ->
            case Float.parse(b) do
              {n, _} -> Map.put(body, "bpm", round(n))
              :error -> body
            end
          b when is_number(b) -> Map.put(body, "bpm", round(b))
        end

      case Req.post(url, json: body) do
        {:ok, %{status: status}} when status in 200..299 ->
          AirlockData.publish(airlock_id, [{:grainfather_last_sent_at, to_string(now_ms())}])
          Logger.info("Grainfather: sent airlock #{airlock_id} (status #{status})")
          :ok

        {:ok, %{status: 429}} ->
          Logger.debug("Grainfather: throttled (429)")
          :throttled

        {:ok, %{status: 422, body: body}} ->
          Logger.warning("Grainfather: validation error 422 #{inspect(body)}")
          :error

        {:ok, %{status: status, body: body}} ->
          Logger.warning("Grainfather: unexpected response #{status} #{inspect(body)}")
          :error

        {:error, reason} ->
          Logger.error("Grainfather: request failed #{inspect(reason)}")
          :error
      end
    end
  end

  defp parse_number(nil), do: nil
  defp parse_number(n) when is_number(n), do: n * 1.0

  defp parse_number(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_number(_), do: nil

  defp parse_specific_gravity(nil), do: 1.0
  defp parse_specific_gravity(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 1.0
    end
  end
  defp parse_specific_gravity(n) when is_number(n), do: n * 1.0
  defp parse_specific_gravity(_), do: 1.0

  defp temp_for_unit(t, "fahrenheit"), do: t * 9 / 5 + 32
  defp temp_for_unit(t, _), do: t
end
