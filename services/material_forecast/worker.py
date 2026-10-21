"""Run from any working directory: python services/material_forecast/worker.py --help."""

import sys
from pathlib import Path
sys.dont_write_bytecode = True
# The managed launcher uses -I, which excludes the script directory as well as
# PYTHONPATH/CWD. Import only the package next to this verified payload entry.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from forecast_worker.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
