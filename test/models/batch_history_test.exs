defmodule OpenPlaatoKeg.Models.BatchHistoryTest do
  use ExUnit.Case

  alias OpenPlaatoKeg.Models.BatchHistory

  setup do
    :dets.close(:batch_history)

    unique = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "open_plaato_keg_history_test_#{unique}")
    File.mkdir_p!(dir)

    {:ok, _} =
      :dets.open_file(:batch_history, file: String.to_charlist(Path.join(dir, "history.dets")))

    on_exit(fn ->
      :dets.close(:batch_history)
      File.rm_rf(dir)
    end)

    :ok
  end

  test "delete removes only the matching entry of that device" do
    :dets.insert(:batch_history, {{:airlock, "a1", 100}, %{"label" => "test run"}})
    :dets.insert(:batch_history, {{:airlock, "a1", 200}, %{"label" => "real batch"}})
    :dets.insert(:batch_history, {{:airlock, "a2", 100}, %{"label" => "other device"}})
    :dets.insert(:batch_history, {{:keg, "a1", 100}, %{"label" => "keg"}})

    assert BatchHistory.delete(:airlock, "a1", 100) == :ok

    assert BatchHistory.list(:airlock, "a1") == [%{"label" => "real batch", "archived_at" => 200}]
    assert [%{"label" => "other device"}] = BatchHistory.list(:airlock, "a2")
    assert [%{"label" => "keg"}] = BatchHistory.list(:keg, "a1")
  end

  test "delete returns :not_found for an unknown entry" do
    :dets.insert(:batch_history, {{:airlock, "a1", 100}, %{"label" => "x"}})

    assert BatchHistory.delete(:airlock, "a1", 999) == :not_found
    assert BatchHistory.delete(:keg, "a1", 100) == :not_found
    assert length(BatchHistory.list(:airlock, "a1")) == 1
  end
end
