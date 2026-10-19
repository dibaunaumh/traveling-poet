defmodule TravelingPoet.LocaleTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Locale

  @day ~D[2026-10-18]

  test "English dates read exactly as they did before a second language" do
    assert Locale.format_date(@day, :long, "en") == Calendar.strftime(@day, "%B %-d, %Y")
    assert Locale.format_date(@day, :short, "en") == "Oct 18"
    assert Locale.format_date(@day, :weekday_long, "en") == "Sunday, October 18, 2026"
    assert Locale.format_date(@day, :month_year, "en") == "October 2026"
  end

  test "Hebrew dates put the day first and the month with ב-" do
    assert Locale.format_date(@day, :long, "he") == "18 באוקטובר 2026"
    assert Locale.format_date(@day, :short, "he") == "18 באוק׳"
    assert Locale.format_date(@day, :weekday_long, "he") == "יום ראשון, 18 באוקטובר 2026"
    assert Locale.format_date(~D[2026-05-02], :month_day, "he") == "2 במאי"
  end

  test "without a locale, the process's own" do
    assert Locale.with_locale("he", fn -> Locale.format_date(@day, :short) end) == "18 באוק׳"
    assert Locale.with_locale("en", fn -> Locale.format_date(@day, :short) end) == "Oct 18"
  end

  test "labels around dates follow the process's language" do
    assert Locale.with_locale("he", fn ->
             TravelingPoet.Trips.date_range(~D[2026-10-03], ~D[2026-10-09])
           end) == "3 עד 9 באוקטובר"

    assert TravelingPoet.Trips.date_range(~D[2026-12-30], ~D[2027-01-02]) ==
             "30 December to 2 January 2027"
  end
end
