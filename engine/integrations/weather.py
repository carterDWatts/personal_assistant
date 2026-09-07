"""Live forecasts without accounts or API keys, via Open-Meteo."""

import asyncio
import json
import time
from datetime import datetime, timezone
from urllib.parse import urlencode
from urllib.request import urlopen

_CACHE = {}
TTL = 300


def _get(url, params):
    request = url + "?" + urlencode(params)
    now = time.monotonic()
    if request in _CACHE and now - _CACHE[request][0] < TTL:
        return _CACHE[request][1]
    with urlopen(request, timeout=10) as response:
        data = json.load(response)
    if data.get("error"):
        raise ValueError(data.get("reason", "Forecast unavailable"))
    result = (data, datetime.now(timezone.utc).isoformat())
    if len(_CACHE) >= 32:
        _CACHE.clear()
    _CACHE[request] = (now, result)
    return result


def _rows(series):
    return [dict(zip(series, values)) for values in zip(*series.values())] if series else []


def _forecast(args):
    places, _ = _get("https://geocoding-api.open-meteo.com/v1/search", {
        "name": args["location"], "count": 3, "language": "en", "format": "json"})
    matches = places.get("results", [])
    if not matches:
        return {"error": "Location not found. Ask for a city and state or country."}
    place = matches[0]
    metric = args.get("units", "us") == "metric"
    data, fetched = _get("https://api.open-meteo.com/v1/forecast", {
        "latitude": place["latitude"], "longitude": place["longitude"], "timezone": "auto",
        "temperature_unit": "celsius" if metric else "fahrenheit",
        "wind_speed_unit": "kmh" if metric else "mph",
        "precipitation_unit": "mm" if metric else "inch",
        "current": "temperature_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m,wind_gusts_10m",
        "hourly": "temperature_2m,precipitation_probability,precipitation,wind_speed_10m,wind_gusts_10m",
        "daily": "temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,wind_speed_10m_max,wind_gusts_10m_max,sunrise,sunset",
        "forecast_days": 7})
    current = data.get("current", {})
    hours = [row for row in _rows(data.get("hourly")) if row["time"] >= current.get("time", "")[:13] + ":00"][:24]
    return {
        "source": "Open-Meteo", "source_url": "https://open-meteo.com/", "fetched_at": fetched,
        "cache_max_age_seconds": TTL, "timezone": data["timezone"],
        "location": ", ".join(str(place[k]) for k in ("name", "admin1", "country") if place.get(k)),
        "coordinates": {"latitude": place["latitude"], "longitude": place["longitude"]},
        "current": current, "current_units": data.get("current_units", {}),
        "next_24_hours": hours, "hourly_units": data.get("hourly_units", {}),
        "daily": _rows(data.get("daily")), "daily_units": data.get("daily_units", {}),
        "note": "Model-based weather estimates and forecasts, not a guarantee or a severe-weather alert service."}


async def forecast(args):
    try:
        return await asyncio.to_thread(_forecast, args)
    except (OSError, ValueError, KeyError, TypeError):
        from engine.tools import ToolError
        raise ToolError("Live weather is temporarily unavailable. Do not substitute an old forecast or guess.") from None
