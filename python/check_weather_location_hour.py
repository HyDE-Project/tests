"""weather.py's first-day cutoff must follow the weather location's clock.

wttr.in's hourly slots use the location's local time, so the cutoff comes from
current_condition[0].localObsDateTime, not the host clock
(HyDE-Project/HyDE#2159). Anything unusable falls back to the host hour.
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import re
import unittest

REPO_ROOT = pathlib.Path(os.environ.get("REPO_ROOT", "."))
SCRIPT = REPO_ROOT / "Configs" / ".local" / "lib" / "hyde" / "weather.py"

spec = importlib.util.spec_from_file_location("hyde_weather", SCRIPT)
assert spec and spec.loader
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)

HOST = 10


def obs(value):
    return {"current_condition": [{"localObsDateTime": value}]}


class LocationHour(unittest.TestCase):
    def test_pm_and_am(self):
        self.assertEqual(w.get_location_hour(obs("2026-09-30 08:15 PM"), HOST), 20)
        self.assertEqual(w.get_location_hour(obs("2026-09-30 08:15 AM"), HOST), 8)

    def test_twelve_boundaries(self):
        self.assertEqual(w.get_location_hour(obs("2026-09-30 12:00 AM"), HOST), 0)
        self.assertEqual(w.get_location_hour(obs("2026-09-30 12:59 PM"), HOST), 12)
        self.assertEqual(w.get_location_hour(obs("2026-09-30 01:00 AM"), HOST), 1)
        self.assertEqual(w.get_location_hour(obs("2026-09-30 11:59 PM"), HOST), 23)

    def test_other_date_than_host_is_irrelevant(self):
        self.assertEqual(w.get_location_hour(obs("1999-01-01 07:00 AM"), HOST), 7)

    def test_lowercase_suffix(self):
        self.assertEqual(w.get_location_hour(obs("2026-09-30 08:15 pm"), HOST), 20)

    def test_fallback_when_missing(self):
        for weather in ({}, {"current_condition": []}, {"current_condition": [{}]},
                        {"current_condition": None}, {"current_condition": "x"},
                        {"current_condition": [None]}):
            self.assertEqual(w.get_location_hour(weather, HOST), HOST, weather)

    def test_fallback_when_malformed(self):
        for bad in ("", "garbage", "2026-09-30", "2026-09-30 08:15", "2026-09-30 20:15 PM",
                    "2026-09-30 00:15 AM", "2026-09-30 13:00 PM", "2026-09-30 08:60 PM",
                    "2026-09-30 -8:15 PM", "2026-09-30 08:xx PM", "2026-09-30 08 PM",
                    "2026-09-30 08:15 XM", "2026-09-30 08:15 PM extra", None, 5, [], {}):
            self.assertEqual(w.get_location_hour(obs(bad), HOST), HOST, repr(bad))

    def test_fallback_is_returned_unchanged(self):
        for fb in (0, 23):
            self.assertEqual(w.get_location_hour(obs("junk"), fb), fb)


class CutoffUsesLocationClock(unittest.TestCase):
    @staticmethod
    def hours(weather, now):
        text = re.sub(r"<[^>]+>", "", w.build_forecast(weather, now, 1))
        return [int(m) for m in re.findall(r"^\s*(\d{1,2})\s", text, re.M)]

    def day(self):
        slots = [{"time": str(h * 100), "weatherCode": "113", "weatherDesc": [{"value": "Sunny"}],
                  "tempC": "10", "tempF": "50"} for h in (0, 3, 6, 9, 12, 15, 18, 21)]
        return {"weather": [{"hourly": slots}]}

    def test_location_behind_host_keeps_current_slots(self):
        # host hour 10, location hour 7: the 6:00 slot is still current
        loc = w.get_location_hour({**self.day(), **obs("2026-09-30 07:00 AM")}, 10)
        self.assertEqual(loc, 7)
        self.assertIn(6, self.hours(self.day(), loc))
        self.assertNotIn(6, self.hours(self.day(), 10))

    def test_location_ahead_of_host_drops_past_slots(self):
        loc = w.get_location_hour({**self.day(), **obs("2026-09-30 09:00 PM")}, 10)
        self.assertEqual(loc, 21)
        self.assertNotIn(12, self.hours(self.day(), loc))


if __name__ == "__main__":
    unittest.main()
