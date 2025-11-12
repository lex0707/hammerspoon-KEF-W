"""Storage helpers for persisting Oura API data."""
from __future__ import annotations

from collections.abc import Mapping
from pathlib import Path
from typing import Any
import csv
import json

from .utils import flatten_dict, select_row_identity


class DataStore:
    """Manage CSV output files and deduplicate incoming records."""

    def __init__(self, root: str | Path) -> None:
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)

    def write_records(self, category: str, records: list[Mapping[str, Any]]) -> int:
        """Write records for a category and return the number of new rows added."""
        if not records:
            return 0
        flattened = [flatten_dict(dict(record)) for record in records]
        return self._write_csv(category, flattened)

    def _write_csv(self, category: str, rows: list[dict[str, Any]]) -> int:
        file_path = self.root / f"{category}.csv"
        existing_rows: dict[str, dict[str, Any]] = {}

        if file_path.exists():
            with file_path.open("r", newline="", encoding="utf-8") as handle:
                reader = csv.DictReader(handle)
                for row in reader:
                    key = row.get("__identity__") or select_row_identity(row)
                    existing_rows[key] = row

        added = 0
        for row in rows:
            key = select_row_identity(row)
            if key not in existing_rows:
                added += 1
            existing_rows[key] = {**row, "__identity__": key}

        if not existing_rows:
            return 0

        all_keys: set[str] = set()
        for row in existing_rows.values():
            all_keys.update(row.keys())

        fieldnames = sorted(all_keys)
        with file_path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames)
            writer.writeheader()
            for row in existing_rows.values():
                writer.writerow({key: row.get(key, "") for key in fieldnames})
        return added


class StateStore:
    """Persist fetch metadata to a JSON file."""

    def __init__(self, file_path: str | Path) -> None:
        self.file_path = Path(file_path)
        if not self.file_path.parent.exists():
            self.file_path.parent.mkdir(parents=True, exist_ok=True)

    def load(self) -> dict[str, Any]:
        if not self.file_path.exists():
            return {"categories": {}}
        with self.file_path.open("r", encoding="utf-8") as handle:
            return json.load(handle)

    def save(self, state: dict[str, Any]) -> None:
        with self.file_path.open("w", encoding="utf-8") as handle:
            json.dump(state, handle, indent=2, sort_keys=True)
