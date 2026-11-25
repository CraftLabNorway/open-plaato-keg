defmodule OpenPlaatoKeg.BarHelperKegTest do
  use ExUnit.Case
  use Plug.Test
  import ExUnit.CaptureLog

  alias OpenPlaatoKeg.BarHelperKeg
  alias OpenPlaatoKeg.HttpRouter
  alias OpenPlaatoKeg.Models.BarHelperConfig
  alias OpenPlaatoKeg.Models.KegData

  @key "bh-secret-KEY-1234567890abcdef"

  # mix test runs with --no-start; Req (and Finch) are needed for real HTTP.
  setup_all do
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  @keg "keg-token-abc123"

  setup do
    for t <- [:keg_data, :airlock_data, :barhelper_config], do: :dets.close(t)
    dir = Path.join(System.tmp_dir!(), "opk_barhelper_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for {t, f} <- [keg_data: "kegs", airlock_data: "airlocks", barhelper_config: "bh"] do
      {:ok, _} = :dets.open_file(t, file: String.to_charlist(Path.join(dir, f <> ".dets")))
    end

    KegData.publish(@keg, id: @keg, amount_left: "12.5", keg_temperature: "4.2")

    {:ok, calls} = Agent.start_link(fn -> [] end)
    stub(calls, 200, ~s({"success": true, "message": "Keg Monitor updated successfully"}))

    on_exit(fn ->
      Application.delete_env(:open_plaato_keg, :barhelper_keg_req_options)
      Application.delete_env(:open_plaato_keg, :barhelper_keg_host)
      for t <- [:keg_data, :airlock_data, :barhelper_config], do: :dets.close(t)
      File.rm_rf(dir)
    end)

    {:ok, calls: calls}
  end

  # Req plug stub standing in for BarHelper; records each request.
  defp stub(calls, status, body) do
    Application.put_env(:open_plaato_keg, :barhelper_keg_req_options,
      plug: fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        auth = Plug.Conn.get_req_header(conn, "authorization")
        Agent.update(calls, &[%{auth: auth, body: Poison.decode!(raw)} | &1])
        Plug.Conn.send_resp(conn, status, body)
      end
    )
  end

  defp request(method, path, body \\ nil) do
    conn =
      if body,
        do:
          conn(method, path, Poison.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    conn = HttpRouter.call(conn, HttpRouter.init([]))
    {conn.status, conn.resp_body}
  end

  defp configure(extra \\ %{}) do
    request(
      :post,
      "/api/kegs/#{@keg}/barhelper",
      Map.merge(%{enabled: true, api_key: @key, monitor_id: "tap-1", unit: "l"}, extra)
    )
  end

  test "saves settings and never returns the key" do
    {status, body} = configure()
    assert status == 200
    refute body =~ @key
    resp = Poison.decode!(body)
    assert resp["configured"] == true
    assert resp["enabled"] == true
    assert resp["monitor_id"] == "tap-1"
    refute Map.has_key?(resp, "api_key")
    assert BarHelperConfig.get(@keg)[:api_key] == @key
  end

  test "the key never appears in public keg JSON or keg data" do
    configure()

    for path <- ["/api/kegs/#{@keg}", "/api/kegs", "/api/kegs/#{@keg}/barhelper"] do
      {200, body} = request(:get, path)
      refute body =~ @key, "key leaked in #{path}"
    end

    # WebSocket, MQTT and metrics publish keg data; the key is not in that table at all.
    refute inspect(:dets.match_object(:keg_data, :_)) =~ @key
    refute inspect(KegData.all()) =~ @key
  end

  test "empty api_key keeps the stored key, clear_api_key removes it" do
    configure()

    {200, _} =
      request(:post, "/api/kegs/#{@keg}/barhelper", %{
        enabled: true,
        api_key: "",
        monitor_id: "tap-2",
        unit: "gal"
      })

    assert BarHelperConfig.get(@keg)[:api_key] == @key
    assert BarHelperConfig.get(@keg)[:unit] == "gal"

    {200, body} =
      request(:post, "/api/kegs/#{@keg}/barhelper", %{enabled: false, clear_api_key: true})

    assert Poison.decode!(body)["configured"] == false
  end

  test "validation and unknown kegs" do
    assert {422, _} =
             request(:post, "/api/kegs/#{@keg}/barhelper", %{enabled: true, monitor_id: "tap-1"})

    assert {422, _} = configure(%{unit: "pints"})
    assert {422, _} = configure(%{monitor_id: ""})
    assert {404, _} = request(:post, "/api/kegs/nope/barhelper", %{enabled: false})
    assert {404, _} = request(:get, "/api/kegs/nope/barhelper")
  end

  test "send test posts the current amount with the owner's key", %{calls: calls} do
    configure()
    {200, body} = request(:post, "/api/kegs/#{@keg}/barhelper/test")
    resp = Poison.decode!(body)
    assert resp["status"] == "ok"
    assert resp["last_status"] == "ok"
    assert is_integer(resp["last_sent_at"])
    refute body =~ @key

    assert [%{auth: [@key], body: %{"name" => "tap-1", "volume" => 12.5, "type" => "l"}}] =
             Agent.get(calls, & &1)
  end

  test "a wrong key gives a clear error and the key is not logged or returned", %{calls: calls} do
    stub(calls, 401, "Wrong auth key " <> @key)
    configure()

    log =
      capture_log(fn ->
        {200, body} = request(:post, "/api/kegs/#{@keg}/barhelper/test")
        resp = Poison.decode!(body)
        assert resp["status"] == "error"
        assert resp["message"] =~ "rejected the API key"
        refute body =~ @key
      end)

    refute log =~ @key
    refute inspect(BarHelperConfig.public(@keg)) =~ @key
  end

  test "an echoed key in an error body is redacted", %{calls: calls} do
    stub(calls, 500, "internal error for " <> @key)
    configure()
    {200, body} = request(:post, "/api/kegs/#{@keg}/barhelper/test")
    refute body =~ @key
    assert body =~ "[hidden]"
  end

  test "BarHelper unreachable: error, no crash, nothing logged with the key" do
    Application.delete_env(:open_plaato_keg, :barhelper_keg_req_options)
    Application.put_env(:open_plaato_keg, :barhelper_keg_host, "http://127.0.0.1:1/customKegMon")
    configure()

    log =
      capture_log(fn ->
        assert {:error, msg} = BarHelperKeg.test_send(@keg)
        assert msg =~ "Could not reach BarHelper"
      end)

    refute log =~ @key
  end

  test "live updates: only changed amounts, at most once a minute", %{calls: calls} do
    start_supervised!({Task.Supervisor, name: OpenPlaatoKeg.BarHelperTaskSupervisor})
    start_supervised!(BarHelperKeg)
    configure()

    BarHelperKeg.publish(@keg, amount_left: "12.0")
    wait_for(fn -> length(Agent.get(calls, & &1)) == 1 end)

    # Same value again, then a new one inside the minute: nothing more goes out now.
    BarHelperKeg.publish(@keg, amount_left: "12.0")
    BarHelperKeg.publish(@keg, amount_left: "11.6")
    Process.sleep(300)
    assert length(Agent.get(calls, & &1)) == 1
    assert BarHelperConfig.get(@keg)[:last_amount_sent] == 12.0

    # Disabled kegs send nothing.
    request(:post, "/api/kegs/#{@keg}/barhelper", %{enabled: false})
    BarHelperKeg.publish("other-keg", amount_left: "3")
    Process.sleep(100)
    assert length(Agent.get(calls, & &1)) == 1
  end

  defp wait_for(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end
end
