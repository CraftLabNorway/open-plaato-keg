defmodule OpenPlaatoKeg.BarHelperKeg do
  @moduledoc """
  Per-keg BarHelper integration for a public multi-user server.

  Each keg owner sets their own API key, monitor id and unit via
  POST /api/kegs/:id/barhelper (see `OpenPlaatoKeg.Models.BarHelperConfig`).
  The global env-configured `OpenPlaatoKeg.BarHelper` is left as it is.

  Sending rules:
  - only when amount_left changed (the keg processor only calls `publish/2` then)
    and differs from the last value sent;
  - at most once per `@min_interval_ms` per keg; a change inside that window is
    sent when the window ends (latest value wins);
  - the HTTP call runs in a supervised task with short timeouts and no retries,
    so a bad key or BarHelper being down never blocks or crashes the keg listener.

  The API key is never logged and is removed from any error text kept or returned.
  """
  use GenServer
  require Logger

  alias OpenPlaatoKeg.Models.BarHelperConfig
  alias OpenPlaatoKeg.Models.KegData

  @default_host "https://europe-west1-barhelper-app.cloudfunctions.net/api/customKegMon"
  @min_interval_ms 60_000
  @timeout_ms 5_000

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Called by the keg data processor when amount_left changed. Never blocks or raises."
  def publish(id, data) do
    case Keyword.get(data, :amount_left) do
      nil -> :ok
      amount -> GenServer.cast(__MODULE__, {:amount, id, amount})
    end
  end

  @doc "Send the keg's current amount right now (the \"Send test\" button). Returns {:ok, msg} | {:error, msg}."
  def test_send(id) do
    settings = BarHelperConfig.get(id)

    cond do
      not BarHelperConfig.configured?(settings) ->
        {:error, "Add your BarHelper API key first."}

      (settings[:monitor_id] || "") == "" ->
        {:error, "Add the keg monitor ID first."}

      true ->
        case parse_amount(KegData.get(id)[:amount_left]) do
          nil -> {:error, "The keg has not reported an amount yet."}
          amount -> deliver(id, settings, amount)
        end
    end
  end

  @impl true
  def init(_), do: {:ok, %{pending: %{}, timers: %{}}}

  @impl true
  def handle_cast({:amount, id, raw_amount}, state) do
    settings = BarHelperConfig.get(id)
    amount = parse_amount(raw_amount)

    if amount != nil and active?(settings) and amount != settings[:last_amount_sent] do
      wait = wait_ms(settings)

      if wait == 0 and not Map.has_key?(state.timers, id) do
        start_send(id, amount)
        {:noreply, state}
      else
        {:noreply, schedule(state, id, amount, max(wait, 1_000))}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:flush, id}, state) do
    {amount, pending} = Map.pop(state.pending, id)
    state = %{state | pending: pending, timers: Map.delete(state.timers, id)}
    settings = BarHelperConfig.get(id)

    if amount != nil and active?(settings) and amount != settings[:last_amount_sent] do
      start_send(id, amount)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  def deliver(id, settings, amount) do
    key = settings[:api_key] || ""

    result =
      try do
        request(key, settings[:monitor_id], amount, settings[:unit] || "l")
      rescue
        e -> {:error, "Request failed (#{e.__struct__ |> Module.split() |> List.last()})"}
      end

    result = redact(result, key)
    now = now_ms()

    case result do
      {:ok, msg} ->
        BarHelperConfig.put(id, %{
          last_status: "ok",
          last_error: nil,
          last_sent_at: now,
          last_attempt_at: now,
          last_amount_sent: amount
        })

        Logger.info("BarHelper: keg #{short(id)} sent #{amount}")
        {:ok, msg}

      {:error, msg} ->
        BarHelperConfig.put(id, %{last_status: "error", last_error: msg, last_attempt_at: now})
        Logger.warning("BarHelper: keg #{short(id)} not sent: #{msg}")
        {:error, msg}
    end
  end

  defp schedule(state, id, amount, wait) do
    timers =
      if Map.has_key?(state.timers, id),
        do: state.timers,
        else: Map.put(state.timers, id, Process.send_after(self(), {:flush, id}, wait))

    %{state | pending: Map.put(state.pending, id, amount), timers: timers}
  end

  defp start_send(id, amount) do
    # Mark the attempt first, so the rate limit holds even if the task is slow.
    BarHelperConfig.put(id, %{last_attempt_at: now_ms()})

    Task.Supervisor.start_child(OpenPlaatoKeg.BarHelperTaskSupervisor, fn ->
      deliver(id, BarHelperConfig.get(id), amount)
    end)
  end

  defp active?(s),
    do: s[:enabled] == true and BarHelperConfig.configured?(s) and (s[:monitor_id] || "") != ""

  defp wait_ms(settings) do
    case settings[:last_attempt_at] do
      ts when is_integer(ts) -> max(0, ts + @min_interval_ms - now_ms())
      _ -> 0
    end
  end

  defp request(key, monitor_id, amount, unit) do
    opts =
      [
        json: %{name: monitor_id, volume: amount, type: unit},
        headers: [{"authorization", key}],
        receive_timeout: @timeout_ms,
        connect_options: [timeout: @timeout_ms],
        retry: false
      ] ++ Application.get_env(:open_plaato_keg, :barhelper_keg_req_options, [])

    case Req.post(host(), opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        if success_body?(body),
          do: {:ok, "Sent #{amount} #{unit} to monitor \"#{monitor_id}\"."},
          else: {:error, "BarHelper did not accept the update: #{snippet(body)}"}

      {:ok, %{status: status, body: body}} ->
        text = snippet(body)

        if String.starts_with?(text, "Wrong auth") or status in [401, 403],
          do: {:error, "BarHelper rejected the API key (HTTP #{status})."},
          else: {:error, "BarHelper answered HTTP #{status}: #{text}"}

      {:error, %{__exception__: true} = e} ->
        {:error, "Could not reach BarHelper (#{Exception.message(e) |> String.slice(0, 80)})"}

      {:error, _} ->
        {:error, "Could not reach BarHelper."}
    end
  end

  defp success_body?(%{"success" => true}), do: true
  defp success_body?(body) when is_binary(body), do: body =~ ~r/"success"\s*:\s*true/
  defp success_body?(_), do: false

  defp snippet(body) when is_binary(body), do: body |> String.slice(0, 120) |> String.trim()
  defp snippet(body), do: body |> Poison.encode!() |> String.slice(0, 120)

  # The key must never come back in a message, even if BarHelper echoes it.
  defp redact({tag, msg}, key) when byte_size(key) >= 4,
    do: {tag, String.replace(msg, key, "[hidden]")}

  defp redact(result, _key), do: result

  defp host do
    Application.get_env(:open_plaato_keg, :barhelper_keg_host) ||
      (OpenPlaatoKeg.barhelper_config() || [])[:host] || @default_host
  end

  defp parse_amount(nil), do: nil
  defp parse_amount(n) when is_number(n), do: Float.round(n * 1.0, 3)

  defp parse_amount(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, _} -> Float.round(f, 3)
      :error -> nil
    end
  end

  defp parse_amount(_), do: nil

  defp short(id), do: id |> to_string() |> String.slice(0, 6)
  defp now_ms, do: System.system_time(:millisecond)
end
