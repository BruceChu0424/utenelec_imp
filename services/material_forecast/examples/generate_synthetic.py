"""SYNTHETIC demonstration only; never write output to the ERP snapshot directory."""

import argparse
import csv
import json
import random
from datetime import datetime, time, timedelta, timezone
from pathlib import Path


def generate(directory: Path, count: int = 900) -> tuple[Path, Path]:
    directory.mkdir(parents=True, exist_ok=True)
    manifest = {
        "seriesId": "synthetic_demo", "name": "SYNTHETIC - not market data",
        "commodity": "COPPER", "market": "SPOT", "grade": "SYNTHETIC",
        "region": "SYNTHETIC", "currency": "CNY", "unit": "元/吨",
        "priceBasis": "SYNTHETIC demonstration; no commercial meaning",
        "sourceName": "SYNTHETIC deterministic test generator",
        "sourceUrl": "https://example.invalid/SYNTHETIC", "authorized": True,
        "rollPolicy": None, "synthetic": True,
    }
    manifest_path = directory / "SYNTHETIC.manifest.json"
    csv_path = directory / "SYNTHETIC.prices.csv"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    day = datetime.now(timezone.utc).date() - timedelta(days=1)
    days = []
    while len(days) < count:
        if day.weekday() < 5:
            days.append(day)
        day -= timedelta(days=1)
    rng = random.Random(8128)
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["date", "price", "available_at"])
        for index, day in enumerate(reversed(days)):
            # Artificially easy drifting series exercises the entire real-library path.
            price = 50000 + 12 * index + rng.gauss(0, 1.2)
            published = datetime.combine(day, time(16), timezone.utc).isoformat()
            writer.writerow([day.isoformat(), f"{price:.6f}", published])
    return manifest_path, csv_path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path(__file__).parent / "generated")
    args = parser.parse_args()
    for path in generate(args.directory):
        print(path.resolve())
