defmodule OpenPlaatoKeg.GravityEstimateTest do
  use ExUnit.Case, async: true
  alias OpenPlaatoKeg.GravityEstimate

  test "no bubbles yet returns OG" do
    assert GravityEstimate.estimate(1.050, 20, 0) == 1.050
  end

  test "typical 5% beer lands near expected FG" do
    # 20 L, OG 1.050 -> FG ~1.010 needs ~792 g CO2 produced; 32 g dissolved
    bubbles = round((792 - 32) / 0.00183)
    assert_in_delta GravityEstimate.estimate(1.050, 20, bubbles, 1.0), 1.010, 0.001
  end

  test "never drops below 0.990" do
    assert GravityEstimate.estimate(1.050, 20, 10_000_000, 1.0) == 0.99
  end

  test "missing or invalid inputs return nil" do
    assert GravityEstimate.estimate(nil, 20, 100) == nil
    assert GravityEstimate.estimate(1.050, 0, 100) == nil
    assert GravityEstimate.estimate(1.0, 20, 100) == nil
  end

  test "calibration round-trips with estimate" do
    ml = GravityEstimate.calibrate_bubble_ml(1.060, 23, 150_000, 1.020)
    assert is_float(ml)
    assert_in_delta GravityEstimate.estimate(1.060, 23, 150_000, ml), 1.020, 0.001
  end

  test "calibration rejects impossible readings" do
    assert GravityEstimate.calibrate_bubble_ml(1.050, 20, 0, 1.040) == nil
    assert GravityEstimate.calibrate_bubble_ml(1.050, 20, 1000, 1.055) == nil
  end
end
