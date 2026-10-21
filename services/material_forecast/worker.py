"""Run from any working directory: python services/material_forecast/worker.py --help."""

from forecast_worker.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
