# Oura Ring Data Collector

This project provides a small command line utility that pulls metric data from the Oura Cloud API and stores the results as CSV files. It can be executed on demand or as a long-running service that refreshes the logs every two hours.

## Features

- Downloads every available user collection category that the Oura API exposes (sleep, readiness, activity, workouts, tags, sessions, heart rate, and more).
- Writes a dedicated CSV file per category in a configurable output directory.
- Deduplicates entries automatically using the identifiers supplied by the API.
- Tracks the last successful collection for each category so that subsequent runs only request fresh data.
- Provides both a single-run `fetch` command and a background-style `service` command that executes at a configurable interval (two hours by default).

## Requirements

- Python 3.11 or newer.
- An Oura personal access token with at least the `session`, `workout`, `tag`, and `personal` scopes.

The project depends on the [`requests`](https://pypi.org/project/requests/) library, which will be installed automatically when the package is installed.

## Installation

1. Create and activate a virtual environment (recommended):

   ```bash
   python -m venv .venv
   source .venv/bin/activate
   ```

2. Install the project in editable mode:

   ```bash
   pip install -e .
   ```

## Configuration

Set your Oura personal access token in the `OURA_PERSONAL_ACCESS_TOKEN` environment variable or pass it explicitly via the `--token` command-line flag.

By default, CSV files will be written to the `./data` directory and the fetch state will be stored in `./.oura_state.json`. Both locations are configurable via the `--output-dir` and `--state-file` flags.

## Usage

Fetch data immediately for every category:

```bash
python -m oura_stats.cli fetch --token "<YOUR_TOKEN>"
```

Fetch only the sleep and daily readiness categories:

```bash
python -m oura_stats.cli fetch --token "<YOUR_TOKEN>" --categories sleep daily_readiness
```

Run the background service that polls the API every two hours (the default interval). The `--max-runs` flag is optional and mostly useful for development/testing:

```bash
python -m oura_stats.cli service --token "<YOUR_TOKEN>" --interval-hours 2
```

CSV files will be generated in the output directory. Each category gets its own CSV file with flattened columns so that nested properties are captured using dot notation (for example, `contributors.sleep_balance`).

## Scheduling

If you prefer to rely on an external scheduler (e.g., `cron` or a systemd timer) instead of running the built-in service loop, invoke the `fetch` command every two hours:

```cron
0 */2 * * * /path/to/venv/bin/python -m oura_stats.cli fetch --token "$OURA_PERSONAL_ACCESS_TOKEN" --output-dir /path/to/data
```

## Development

Run the built-in formatting check (currently there are no additional tooling hooks):

```bash
python -m compileall oura_stats
```

Contributions are welcome. Please open an issue or submit a pull request if you have ideas to improve the collector.
