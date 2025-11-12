"""Command line interface for collecting Oura Ring data."""
from __future__ import annotations

import argparse
import logging
import os
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterable

from .api import CATEGORY_ENDPOINTS, OuraClient
from .storage import DataStore, StateStore


LOGGER = logging.getLogger("oura_stats")


@dataclass
class FetchResult:
    category: str
    total_records: int
    new_records: int


@dataclass
class FetchConfig:
    token: str
    categories: list[str]
    output_dir: str
    state_file: str
    lookback_hours: int


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Collect Oura Ring metrics and store them in CSV files.")
    parser.add_argument(
        "--token",
        help="Oura personal access token. Defaults to the OURA_PERSONAL_ACCESS_TOKEN environment variable.",
        default=os.environ.get("OURA_PERSONAL_ACCESS_TOKEN"),
    )
    parser.add_argument(
        "--output-dir",
        default="data",
        help="Directory where CSV files will be stored (default: ./data).",
    )
    parser.add_argument(
        "--state-file",
        default=".oura_state.json",
        help="Path to the JSON file used to track fetch metadata (default: ./.oura_state.json).",
    )
    parser.add_argument(
        "--lookback-hours",
        type=int,
        default=48,
        help="Number of hours to look back when no prior state exists (default: 48).",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    fetch_parser = subparsers.add_parser("fetch", help="Fetch data immediately.")
    fetch_parser.add_argument(
        "--categories",
        "-c",
        nargs="+",
        default=["all"],
        help="List of categories to fetch. Use 'all' to fetch every available category.",
    )

    service_parser = subparsers.add_parser("service", help="Run a long-lived service that fetches data every few hours.")
    service_parser.add_argument(
        "--categories",
        "-c",
        nargs="+",
        default=["all"],
        help="List of categories to fetch. Use 'all' to fetch every available category.",
    )
    service_parser.add_argument(
        "--interval-hours",
        type=float,
        default=2.0,
        help="How often (in hours) the service should pull data (default: 2).",
    )
    service_parser.add_argument(
        "--max-runs",
        type=int,
        default=None,
        help="Optional limit on the number of collection runs (useful for testing).",
    )

    return parser.parse_args(argv)


def configure_logging() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    configure_logging()

    if not args.token:
        LOGGER.error("An Oura personal access token must be provided via --token or the OURA_PERSONAL_ACCESS_TOKEN environment variable.")
        return 1

    categories = resolve_categories(args.categories)
    config = FetchConfig(
        token=args.token,
        categories=categories,
        output_dir=args.output_dir,
        state_file=args.state_file,
        lookback_hours=args.lookback_hours,
    )

    if args.command == "fetch":
        run = collect_once(config)
        summarize_run(run)
        return 0

    if args.command == "service":
        run_service(config, interval_hours=args.interval_hours, max_runs=args.max_runs)
        return 0

    LOGGER.error("Unknown command: %s", args.command)
    return 1


def resolve_categories(raw: Iterable[str]) -> list[str]:
    values = [value.lower() for value in raw]
    if "all" in values:
        return sorted(CATEGORY_ENDPOINTS.keys())
    available = set(CATEGORY_ENDPOINTS)
    selected = []
    for value in values:
        if value not in available:
            raise SystemExit(f"Unknown category '{value}'. Available: {', '.join(sorted(available))}")
        selected.append(value)
    return selected


def collect_once(config: FetchConfig) -> list[FetchResult]:
    client = OuraClient(config.token)
    data_store = DataStore(config.output_dir)
    state_store = StateStore(config.state_file)

    state = state_store.load()
    category_state = state.setdefault("categories", {})

    now = datetime.now(timezone.utc)
    default_start = now - timedelta(hours=config.lookback_hours)

    results: list[FetchResult] = []

    for category in config.categories:
        start = parse_iso_datetime(category_state.get(category)) if category in category_state else default_start
        LOGGER.info("Fetching %s data from %s to %s", category, start.date(), now.date())
        records = client.fetch_category(category, start=start, end=now)
        new_count = data_store.write_records(category, records)
        category_state[category] = now.isoformat()
        results.append(FetchResult(category=category, total_records=len(records), new_records=new_count))

    state_store.save(state)
    return results


def summarize_run(results: list[FetchResult]) -> None:
    for result in results:
        LOGGER.info(
            "Category %s: %s records fetched, %s new rows written.",
            result.category,
            result.total_records,
            result.new_records,
        )


def run_service(config: FetchConfig, *, interval_hours: float, max_runs: int | None) -> None:
    interval_seconds = max(interval_hours, 0.1) * 3600
    runs = 0
    LOGGER.info("Starting collection service. Interval: %s hours", interval_hours)
    try:
        while max_runs is None or runs < max_runs:
            start_time = time.time()
            LOGGER.info("Starting collection run #%s", runs + 1)
            results = collect_once(config)
            summarize_run(results)
            runs += 1
            elapsed = time.time() - start_time
            sleep_for = max(0.0, interval_seconds - elapsed)
            if max_runs is not None and runs >= max_runs:
                break
            if sleep_for > 0:
                LOGGER.info("Sleeping for %.2f seconds", sleep_for)
                time.sleep(sleep_for)
    except KeyboardInterrupt:
        LOGGER.info("Service interrupted by user. Exiting.")


def parse_iso_datetime(value: str | None) -> datetime:
    if not value:
        return datetime.now(timezone.utc)
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


if __name__ == "__main__":
    sys.exit(main())
