"""Client for interacting with the Oura Cloud API."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, date
from typing import Any, Iterable

import requests


BASE_URL = "https://api.ouraring.com/v2/usercollection"


CATEGORY_ENDPOINTS: dict[str, str] = {
    "sleep": "/sleep",
    "daily_sleep": "/daily_sleep",
    "daily_readiness": "/daily_readiness",
    "daily_activity": "/daily_activity",
    "workout": "/workout",
    "session": "/session",
    "tag": "/tag",
    "rest_mode_period": "/rest_mode_period",
    "daily_spo2": "/daily_spo2",
    "heartrate": "/heartrate",
}


def _ensure_date(value: datetime | date) -> date:
    if isinstance(value, datetime):
        return value.date()
    return value


@dataclass
class OuraClient:
    """Simple HTTP client for the Oura Cloud API."""

    access_token: str
    timeout: float = 30.0

    def __post_init__(self) -> None:
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {self.access_token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        })

    def fetch_category(
        self,
        category: str,
        *,
        start: datetime | date,
        end: datetime | date,
    ) -> list[dict[str, Any]]:
        """Fetch records for a given category in the provided date window."""
        if category not in CATEGORY_ENDPOINTS:
            raise ValueError(f"Unknown category '{category}'. Known categories: {sorted(CATEGORY_ENDPOINTS)}")

        start_date = _ensure_date(start).isoformat()
        end_date = _ensure_date(end).isoformat()

        url = f"{BASE_URL}{CATEGORY_ENDPOINTS[category]}"
        params: dict[str, Any] = {
            "start_date": start_date,
            "end_date": end_date,
            "limit": 200,
        }

        records: list[dict[str, Any]] = []
        next_token: str | None = None

        while True:
            if next_token:
                params["next_token"] = next_token
            response = self.session.get(url, params=params, timeout=self.timeout)
            response.raise_for_status()
            payload = response.json()
            records.extend(_extract_records(payload))
            next_token = payload.get("next_token")
            if not next_token:
                break
        return records


def _extract_records(payload: dict[str, Any]) -> Iterable[dict[str, Any]]:
    for key in ("data", "items"):
        if key in payload and isinstance(payload[key], list):
            return payload[key]
    # For some endpoints the payload key matches the endpoint name.
    for value in payload.values():
        if isinstance(value, list):
            return value
    return []
