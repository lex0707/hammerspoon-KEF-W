"""Utility helpers for the Oura stats project."""
from __future__ import annotations

from collections.abc import Mapping
from typing import Any
import json


def flatten_dict(data: Mapping[str, Any], parent_key: str | None = None) -> dict[str, Any]:
    """Flatten a nested mapping using dot notation for nested keys."""
    items: dict[str, Any] = {}
    for key, value in data.items():
        new_key = f"{parent_key}.{key}" if parent_key else str(key)
        if isinstance(value, Mapping):
            items.update(flatten_dict(value, new_key))
        elif isinstance(value, list):
            items[new_key] = json.dumps(value)
        else:
            items[new_key] = value
    return items


def select_row_identity(row: Mapping[str, Any]) -> str:
    """Select a stable key for a row by looking at known identifier fields."""
    preferred_keys = (
        "id",
        "uuid",
        "day",
        "timestamp",
        "datetime",
        "start_datetime",
        "end_datetime",
        "start_time",
    )
    for key in preferred_keys:
        if key in row and row[key] not in (None, ""):
            return str(row[key])
    # Fallback to a serialized version of the row.
    return json.dumps(row, sort_keys=True)
