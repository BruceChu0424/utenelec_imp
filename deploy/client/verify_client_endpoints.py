"""Verify a built Flutter Windows client carries the approved API endpoints.

The native Release client only ever connects to build-time `API_BASE_URL` and
`CLOUD_API_BASE_URL`; Release ignores user input and local overrides. A formal
package built without one of them silently loses the internal or external entry
(2026-10-30 incident: 2.5.36 shipped without CLOUD_API_BASE_URL, so the client
could never log in from outside). This tool greps the AOT snapshot so such a
bundle is blocked before packaging/publishing instead of after complaints.

Usage:
  python deploy/client/verify_client_endpoints.py \
      --bundle build/windows/x64/runner/Release \
      --require 'https://erp.utenelec.lan/api' \
      --require 'https://justplayit.cn/api'

`--bundle` accepts either the Release bundle directory or the `data/app.so`
file itself. Exit code 0 means every required URL is present.
"""
import argparse
import json
import sys
from pathlib import Path

SNAPSHOT_RELPATH = Path("data") / "app.so"


def find_snapshot(bundle: Path) -> Path:
    bundle = Path(bundle)
    if bundle.is_file():
        return bundle
    candidate = bundle / SNAPSHOT_RELPATH
    if not candidate.is_file():
        raise SystemExit(f"[ERROR] snapshot not found: {candidate}")
    return candidate


def missing_endpoints(snapshot: Path, required: list[str]) -> list[str]:
    blob = snapshot.read_bytes()
    return [url for url in required if url.encode("utf-8") not in blob]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--bundle", required=True,
                        help="Flutter Windows Release bundle directory or data/app.so")
    parser.add_argument("--require", action="append", default=[], metavar="URL",
                        help="exact endpoint URL that must be embedded; repeatable")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args(argv)

    if not args.require:
        parser.error("at least one --require URL is required; refusing to pass vacuously")

    snapshot = find_snapshot(args.bundle)
    missing = missing_endpoints(snapshot, args.require)
    report = {
        "snapshot": str(snapshot),
        "required": args.require,
        "missing": missing,
        "ok": not missing,
    }
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    elif missing:
        print(f"[FAIL] {snapshot}")
        for url in missing:
            print(f"  missing endpoint: {url}")
        print("Rebuild with the corresponding --dart-define before packaging.")
    else:
        print(f"[OK] {snapshot}: all required endpoints embedded")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
