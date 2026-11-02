"""Prepare synthetic rows for the offline browser stress entrypoint only."""
import json
from pathlib import Path

target = Path(__file__).resolve().parents[1] / "build/web/stress-fixture.json"
if not target.parent.is_dir():
    raise SystemExit("Build the Web stability harness first")
data = {"items": [{"id": f"synthetic-{i}", "name": f"Synthetic item {i}",
                   "quantity": "0001.0000000000000001", "amount": "9999999999999.1234567890"}
                  for i in range(50000)]}
target.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
print(f"Prepared 50000 synthetic rows, {target.stat().st_size} bytes")
