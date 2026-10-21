defmodule Dextrin.Temporal do
  @moduledoc """
  DXN's dates and times as text and as numbers (DXN.md §1.2, §1.5, §2.2;
  Jan, 2026-10-20): one place that reads and writes the ISO 8601 strings
  under `@date`, `@time`, `@datetime`, `@local-datetime` and `@duration`,
  and turns a value into the nanoseconds `.dxnb` holds and back.

  A time, datetime or local datetime that fits a microsecond is Elixir's
  own `Time`, `DateTime` or `NaiveDateTime`; one finer is a
  `Dextrin.Nanos`. A datetime keeps its offset: `Z` is UTC, `-00:00`
  (an unknown offset) is refused.
  """

  alias Dextrin.Nanos

  @epoch ~N[1970-01-01 00:00:00]
  @fraction "(?:\\.(\\d{1,9}))?"

  # ---- reading text --------------------------------------------------------------

  @doc "The date `text` writes, `YYYY-MM-DD`."
  @spec parse_date(String.t()) :: {:ok, Date.t()} | :error
  def parse_date(text) do
    with true <- Regex.match?(~r/^\d{4}-\d{2}-\d{2}\z/, text),
         {:ok, date} <- Date.from_iso8601(text) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  @doc "The time `text` writes, `HH:MM:SS` and up to nine fraction digits."
  @spec parse_time(String.t()) :: {:ok, Time.t() | Nanos.t()} | :error
  def parse_time(text) do
    case clock(text) do
      {:ok, nanos} -> {:ok, time_from_nanos(nanos)}
      :error -> :error
    end
  end

  @doc """
  The datetime `text` writes: a date, `T`, a time, and an offset, `Z` or
  `±HH:MM`.
  """
  @spec parse_datetime(String.t()) :: {:ok, DateTime.t() | Nanos.t()} | :error
  def parse_datetime(text) do
    with [_, date, time, offset] <-
           Regex.run(~r/^(\d{4}-\d{2}-\d{2})T([^Z+-]+)(Z|[+-]\d{2}:\d{2})\z/, text),
         {:ok, minutes} <- offset_minutes(offset),
         {:ok, local} <- local_nanos_of(date, time) do
      {:ok, datetime_from(local - minutes * 60 * 1_000_000_000, minutes)}
    else
      _ -> :error
    end
  end

  @doc "The local date-time `text` writes: a date, `T` and a time, no offset."
  @spec parse_local(String.t()) :: {:ok, NaiveDateTime.t() | Nanos.t()} | :error
  def parse_local(text) do
    with [_, date, time] <- Regex.run(~r/^(\d{4}-\d{2}-\d{2})T(.+)\z/, text),
         {:ok, nanos} <- local_nanos_of(date, time) do
      {:ok, local_from(nanos)}
    else
      _ -> :error
    end
  end

  defp local_nanos_of(date_text, time_text) do
    with {:ok, date} <- parse_date(date_text),
         {:ok, clock} <- clock(time_text) do
      {:ok, Date.diff(date, ~D[1970-01-01]) * 86_400_000_000_000 + clock}
    end
  end

  # Nanoseconds since midnight, from `HH:MM:SS(.f{1,9})`.
  defp clock(text) do
    with [_ | parts] <- Regex.run(~r/^(\d{2}):(\d{2}):(\d{2})#{@fraction}\z/, text),
         [h, m, s | rest] = parts,
         {h, m, s} = {String.to_integer(h), String.to_integer(m), String.to_integer(s)},
         true <- h < 24 and m < 60 and s < 60 do
      fraction = rest |> List.first("") |> String.pad_trailing(9, "0")
      fraction = if fraction == "", do: 0, else: String.to_integer(fraction)
      {:ok, ((h * 60 + m) * 60 + s) * 1_000_000_000 + fraction}
    else
      _ -> :error
    end
  end

  defp offset_minutes("Z"), do: {:ok, 0}
  defp offset_minutes("-00:00"), do: :error

  defp offset_minutes(<<sign, h::binary-size(2), ":", m::binary-size(2)>>) do
    {hours, minutes} = {String.to_integer(h), String.to_integer(m)}

    if hours < 24 and minutes < 60,
      do: {:ok, if(sign == ?-, do: -1, else: 1) * (hours * 60 + minutes)},
      else: :error
  end

  # ---- writing text --------------------------------------------------------------

  @doc "`HH:MM:SS`, then the fraction with trailing zeros removed (DXN.md §1.5)."
  @spec time_text(non_neg_integer()) :: String.t()
  def time_text(nanos) do
    seconds = div(nanos, 1_000_000_000)
    fraction = rem(nanos, 1_000_000_000)

    clock =
      [div(seconds, 3600), rem(div(seconds, 60), 60), rem(seconds, 60)]
      |> Enum.map_join(":", &(&1 |> Integer.to_string() |> String.pad_leading(2, "0")))

    case fraction do
      0 ->
        clock

      _ ->
        clock <>
          "." <>
          String.trim_trailing(String.pad_leading(Integer.to_string(fraction), 9, "0"), "0")
    end
  end

  @doc "The text of a datetime: the wall clock at its offset, then `Z` or `±HH:MM`."
  @spec datetime_text(integer(), integer()) :: String.t()
  def datetime_text(epoch_nanos, offset_minutes) do
    local_text(epoch_nanos + offset_minutes * 60 * 1_000_000_000) <> offset_text(offset_minutes)
  end

  @doc "The text of a local date-time: `YYYY-MM-DDTHH:MM:SS` and the fraction."
  @spec local_text(integer()) :: String.t()
  def local_text(local_nanos) do
    day = Integer.floor_div(local_nanos, 86_400_000_000_000)
    clock = local_nanos - day * 86_400_000_000_000
    Date.to_iso8601(Date.add(~D[1970-01-01], day)) <> "T" <> time_text(clock)
  end

  @doc "An offset in minutes as a datetime writes it: `Z`, or `±HH:MM`."
  @spec offset_name(integer()) :: String.t()
  def offset_name(minutes), do: offset_text(minutes)

  defp offset_text(0), do: "Z"

  defp offset_text(minutes) do
    sign = if minutes < 0, do: "-", else: "+"
    abs = abs(minutes)
    sign <> pad2(div(abs, 60)) <> ":" <> pad2(rem(abs, 60))
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc """
  A date, time, datetime, local date-time or duration as its tag and ISO
  8601 text, `{"date", "2026-10-20"}`, or `:error` for any other value --
  what the printer and the canonical form both write.
  """
  @spec tagged(term()) :: {:ok, String.t(), String.t()} | :error
  def tagged(%Date{} = date), do: {:ok, "date", Date.to_iso8601(date)}
  def tagged(%Time{} = time), do: {:ok, "time", time_text(time_nanos(time))}
  def tagged(%DateTime{} = dt), do: datetime_tagged(dt)
  def tagged(%NaiveDateTime{} = n), do: {:ok, "local-datetime", local_text(local_nanos(n))}
  def tagged(%Nanos{value: %Time{}} = t), do: {:ok, "time", time_text(time_nanos(t))}
  def tagged(%Nanos{value: %DateTime{}} = dt), do: datetime_tagged(dt)

  def tagged(%Nanos{value: %NaiveDateTime{}} = n),
    do: {:ok, "local-datetime", local_text(local_nanos(n))}

  def tagged(%Dextrin.Duration{} = d), do: {:ok, "duration", duration_text(d)}
  def tagged(_other), do: :error

  defp datetime_tagged(dt) do
    {nanos, offset} = datetime_parts(dt)
    {:ok, "datetime", datetime_text(nanos, offset)}
  end

  # ---- values and nanoseconds ---------------------------------------------------

  @doc "A time's nanoseconds since midnight."
  @spec time_nanos(Time.t() | Nanos.t()) :: non_neg_integer()
  def time_nanos(%Nanos{value: %Time{} = time, nanosecond: extra}), do: time_nanos(time) + extra

  def time_nanos(%Time{} = time) do
    {micro, _} = time.microsecond
    {seconds, _} = Time.to_seconds_after_midnight(time)
    seconds * 1_000_000_000 + micro * 1000
  end

  @doc "The time `nanos` after midnight."
  @spec time_from_nanos(non_neg_integer()) :: Time.t() | Nanos.t()
  def time_from_nanos(nanos) do
    seconds = div(nanos, 1_000_000_000)
    micro = div(rem(nanos, 1_000_000_000), 1000)
    time = Time.add(~T[00:00:00.000000], seconds) |> Map.put(:microsecond, {micro, 6})
    with_extra(time, rem(nanos, 1000))
  end

  @doc "A datetime as nanoseconds since the epoch and its offset in minutes."
  @spec datetime_parts(DateTime.t() | Nanos.t()) :: {integer(), integer()}
  def datetime_parts(%Nanos{value: %DateTime{} = dt, nanosecond: extra}) do
    {nanos, offset} = datetime_parts(dt)
    {nanos + extra, offset}
  end

  def datetime_parts(%DateTime{} = dt) do
    {DateTime.to_unix(dt, :microsecond) * 1000, div(dt.utc_offset + dt.std_offset, 60)}
  end

  @doc "The datetime `epoch_nanos` after the epoch, written at `offset_minutes`."
  @spec datetime_from(integer(), integer()) :: DateTime.t() | Nanos.t()
  def datetime_from(epoch_nanos, offset_minutes) do
    micro = Integer.floor_div(epoch_nanos, 1000)

    utc =
      micro |> DateTime.from_unix!(:microsecond) |> Map.put(:microsecond, {rem_micro(micro), 6})

    dt =
      if offset_minutes == 0 do
        utc
      else
        naive = NaiveDateTime.add(DateTime.to_naive(utc), offset_minutes * 60, :second)
        # The zone abbreviation the earlier decoders wrote: `+02:00`.
        abbreviation = offset_text(offset_minutes)

        %DateTime{
          year: naive.year,
          month: naive.month,
          day: naive.day,
          hour: naive.hour,
          minute: naive.minute,
          second: naive.second,
          microsecond: {rem_micro(micro), 6},
          time_zone: "fixed",
          zone_abbr: abbreviation,
          utc_offset: offset_minutes * 60,
          std_offset: 0
        }
      end

    with_extra(dt, epoch_nanos - micro * 1000)
  end

  @doc "A local date-time as nanoseconds since 1970-01-01T00:00:00 on the wall clock."
  @spec local_nanos(NaiveDateTime.t() | Nanos.t()) :: integer()
  def local_nanos(%Nanos{value: %NaiveDateTime{} = n, nanosecond: extra}),
    do: local_nanos(n) + extra

  def local_nanos(%NaiveDateTime{} = n), do: NaiveDateTime.diff(n, @epoch, :microsecond) * 1000

  @doc "The local date-time `nanos` after 1970-01-01T00:00:00."
  @spec local_from(integer()) :: NaiveDateTime.t() | Nanos.t()
  def local_from(nanos) do
    micro = Integer.floor_div(nanos, 1000)

    naive =
      @epoch
      |> NaiveDateTime.add(micro, :microsecond)
      |> Map.put(:microsecond, {rem_micro(micro), 6})

    with_extra(naive, nanos - micro * 1000)
  end

  defp rem_micro(micro), do: Integer.mod(micro, 1_000_000)

  defp with_extra(value, 0), do: value
  defp with_extra(value, extra), do: %Nanos{value: value, nanosecond: extra}

  # ---- durations -----------------------------------------------------------------

  @doc """
  The duration `text` writes, `P...` (ISO 8601, a field's sign its own,
  seconds with up to nine fraction digits), as `Dextrin.Duration`'s
  fields.
  """
  @spec parse_duration(String.t()) :: {:ok, Dextrin.Duration.t()} | :error
  def parse_duration(text) do
    pattern =
      ~r/^P(?:(-?\d+)Y)?(?:(-?\d+)M)?(?:(-?\d+)W)?(?:(-?\d+)D)?(?:T(?:(-?\d+)H)?(?:(-?\d+)M)?(?:(-?)(\d+)(?:\.(\d{1,9}))?S)?)?\z/

    case Regex.run(pattern, text) do
      nil ->
        :error

      ["P"] ->
        :error

      [_ | groups] ->
        [y, mo, w, d, h, mi, sign, s, f] = groups ++ List.duplicate("", 9 - length(groups))

        if text |> String.ends_with?("T") do
          :error
        else
          {:ok,
           %Dextrin.Duration{
             years: int(y),
             months: int(mo),
             weeks: int(w),
             days: int(d),
             hours: int(h),
             minutes: int(mi),
             nanoseconds: seconds_nanos(sign, s, f)
           }}
        end
    end
  end

  defp int(""), do: nil
  defp int(digits), do: String.to_integer(digits)

  defp seconds_nanos(_sign, "", _fraction), do: nil

  defp seconds_nanos(sign, seconds, fraction) do
    nanos =
      String.to_integer(seconds) * 1_000_000_000 +
        (fraction |> String.pad_trailing(9, "0") |> fraction_int())

    if sign == "-", do: -nanos, else: nanos
  end

  defp fraction_int(""), do: 0
  defp fraction_int(digits), do: String.to_integer(digits)

  @doc "`P...`: the fields in DXN.md §2.3's order, absent ones left out, `PT0S` when none."
  @spec duration_text(Dextrin.Duration.t()) :: String.t()
  def duration_text(%Dextrin.Duration{} = d) do
    date = part(d.years, "Y") <> part(d.months, "M") <> part(d.weeks, "W") <> part(d.days, "D")
    time = part(d.hours, "H") <> part(d.minutes, "M") <> seconds_part(d.nanoseconds)

    case {date, time} do
      {"", ""} -> "PT0S"
      {date, ""} -> "P" <> date
      {date, time} -> "P" <> date <> "T" <> time
    end
  end

  defp part(nil, _unit), do: ""
  defp part(n, unit), do: Integer.to_string(n) <> unit

  defp seconds_part(nil), do: ""

  defp seconds_part(nanos) do
    sign = if nanos < 0, do: "-", else: ""
    abs = abs(nanos)
    whole = Integer.to_string(div(abs, 1_000_000_000))

    case rem(abs, 1_000_000_000) do
      0 ->
        sign <> whole <> "S"

      f ->
        sign <>
          whole <>
          "." <>
          String.trim_trailing(String.pad_leading(Integer.to_string(f), 9, "0"), "0") <> "S"
    end
  end
end
