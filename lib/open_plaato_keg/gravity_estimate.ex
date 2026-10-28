defmodule OpenPlaatoKeg.GravityEstimate do
  @moduledoc """
  Estimates current specific gravity from airlock bubble counts.

  The Plaato Airlock does not measure gravity. It counts bubbles, so the
  current SG can only be *estimated* from the CO2 that left the fermenter:

      CO2 released (g) = bubbles × bubble volume (ml) × CO2 density (g/ml)
      CO2 produced (g) = CO2 released + CO2 still dissolved in the beer
      OG − SG          = CO2 produced / (batch volume L × 990)

  The last line is the inverse of the standard `ABV = (OG − SG) × 131.25`
  formula combined with fermentation stoichiometry (≈0.956 g CO2 per g
  ethanol, ethanol density 0.789 g/ml). It is a rough estimate: lid leaks,
  bubble size, temperature and dissolved CO2 all affect accuracy. Users can
  calibrate the bubble volume against one hydrometer reading.
  """

  # g/ml at ~20 °C, 1 atm
  @co2_density_g_per_ml 0.00183
  # CO2 that stays dissolved before bubbling starts (~0.85 vol at 20 °C)
  @dissolved_co2_g_per_l 1.6
  # g CO2 per (litre × 1.000 gravity drop), see moduledoc
  @co2_g_per_l_per_sg 990.0
  @default_bubble_ml 1.0
  @min_sg 0.990

  def default_bubble_ml, do: @default_bubble_ml

  @doc """
  Returns the estimated SG rounded to 3 decimals, or `nil` when inputs are
  missing or invalid. `bubbles` is the bubble count since the batch started.
  """
  def estimate(og, batch_volume_l, bubbles, bubble_ml \\ @default_bubble_ml)

  def estimate(og, volume, bubbles, bubble_ml)
      when is_number(og) and is_number(volume) and is_number(bubbles) and
             is_number(bubble_ml) and og > 1.0 and volume > 0 and bubbles >= 0 and
             bubble_ml > 0 do
    drop = co2_produced_g(volume, bubbles, bubble_ml) / (volume * @co2_g_per_l_per_sg)

    (og - drop)
    |> max(@min_sg)
    |> min(og)
    |> Float.round(3)
  end

  def estimate(_, _, _, _), do: nil

  @doc """
  Back-solves the bubble volume (ml) from one hydrometer reading.
  Returns `nil` when it can't be computed (no bubbles yet, reading ≥ OG, etc.).
  """
  def calibrate_bubble_ml(og, volume, bubbles, measured_sg)
      when is_number(og) and is_number(volume) and is_number(bubbles) and
             is_number(measured_sg) and volume > 0 and bubbles > 0 and measured_sg < og do
    co2_produced = (og - measured_sg) * volume * @co2_g_per_l_per_sg
    released = co2_produced - @dissolved_co2_g_per_l * volume

    if released > 0 do
      Float.round(released / (bubbles * @co2_density_g_per_ml), 3)
    else
      nil
    end
  end

  def calibrate_bubble_ml(_, _, _, _), do: nil

  # Bubble counts arrive as floats from DETS strings, so compare with ==.
  defp co2_produced_g(_volume, bubbles, _bubble_ml) when bubbles == 0, do: 0.0

  defp co2_produced_g(volume, bubbles, bubble_ml) do
    bubbles * bubble_ml * @co2_density_g_per_ml + @dissolved_co2_g_per_l * volume
  end
end
