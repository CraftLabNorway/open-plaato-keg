defmodule OpenPlaatoKeg do
  use Application

  def start(_type, _args) do
    OpenPlaatoKeg.Metrics.init()
    bootstrap()
    OpenPlaatoKeg.Supervisor.start_link()
  end

  def bootstrap do
    db_file_path =
      Application.get_env(:open_plaato_keg, :db)[:file_path]

    # create folder if doesn't exist
    db_folder = Path.dirname(db_file_path)
    File.mkdir_p!(db_folder)

    {:ok, _keg_table} =
      :dets.open_file(:keg_data, [
        {:file, String.to_charlist(db_file_path)}
      ])

    # Airlocks are separate from kegs; own DETS file
    airlock_path = Path.join(db_folder, "airlock_data.bin")
    {:ok, _airlock_table} =
      :dets.open_file(:airlock_data, [
        {:file, String.to_charlist(airlock_path)}
      ])

    # Transfer scales: dumb WiFi scales placed under kegs during transfers from fermenter
    transfer_scale_path = Path.join(db_folder, "transfer_scale_data.bin")
    {:ok, _transfer_scale_table} =
      :dets.open_file(:transfer_scale_data, [
        {:file, String.to_charlist(transfer_scale_path)}
      ])

    # Beer DB: tap list configuration and tap handle metadata
    beer_db_path = Path.join(db_folder, "beer_db.bin")
    {:ok, _beer_table} = :dets.open_file(:beer_db, [{:file, String.to_charlist(beer_db_path)}])

    # Beverage library: reusable beverage recipes
    beverages_path = Path.join(db_folder, "beverages.bin")
    {:ok, _} = :dets.open_file(:beverages, [{:file, String.to_charlist(beverages_path)}])

    # Time-series data log for kegs and airlocks
    data_log_path = Path.join(db_folder, "data_log.bin")
    {:ok, _} = :dets.open_file(:data_log, [{:file, String.to_charlist(data_log_path)}])
    OpenPlaatoKeg.Models.DataLog.init_throttle()

    # Web Push subscriptions and alert state (keg empty, leak, temp, fermentation stalled)
    push_subscriptions_path = Path.join(db_folder, "push_subscriptions.bin")
    {:ok, _} =
      :dets.open_file(:push_subscriptions, [{:file, String.to_charlist(push_subscriptions_path)}])

    alert_state_path = Path.join(db_folder, "alert_state.bin")
    {:ok, _} = :dets.open_file(:alert_state, [{:file, String.to_charlist(alert_state_path)}])

    # Ensure tap handle image directory exists (persistent volume)
    File.mkdir_p!(Path.join(db_folder, "tap-handles"))

    OpenPlaatoKeg.AppConfig.load()
    ensure_vapid_keys()
  end

  # Generate a VAPID keypair once and persist it via AppConfig (same DETS volume
  # as everything else), so it survives image rebuilds/redeploys without a
  # code change and doesn't need to be baked into an env var.
  defp ensure_vapid_keys do
    if OpenPlaatoKeg.AppConfig.get(:vapid_public_key, "") == "" do
      keys = ExNudge.generate_vapid_keys()
      OpenPlaatoKeg.AppConfig.put(:vapid_public_key, keys.public_key)
      OpenPlaatoKeg.AppConfig.put(:vapid_private_key, keys.private_key)
    end

    Application.put_env(:ex_nudge, :vapid_subject, push_config()[:vapid_subject])
    Application.put_env(:ex_nudge, :vapid_public_key, OpenPlaatoKeg.AppConfig.get(:vapid_public_key))
    Application.put_env(:ex_nudge, :vapid_private_key, OpenPlaatoKeg.AppConfig.get(:vapid_private_key))
  end

  def tap_handle_dir do
    db_file = Application.get_env(:open_plaato_keg, :db)[:file_path]
    Path.join(Path.dirname(db_file), "tap-handles")
  end

  def tcp_listener_config do
    Application.get_env(:open_plaato_keg, :tcp_listener)
  end

  def http_listener_config do
    Application.get_env(:open_plaato_keg, :http_listener)
  end

  def mqtt_config do
    Application.get_env(:open_plaato_keg, :mqtt)
  end

  def barhelper_config do
    Application.get_env(:open_plaato_keg, :barhelper)
  end

  def push_config do
    Application.get_env(:open_plaato_keg, :push)
  end
end
