#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from policy_lib import PolicyError, build_metadata, canonical_metadata, load_config, render_documents


def main() -> int:
    parser = argparse.ArgumentParser(description="Render Uten IMP Aliyun RAM/OSS policies")
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    base = Path(__file__).resolve().parent
    try:
        config = load_config(args.config)
        if args.output.exists():
            raise PolicyError("output must not already exist")
        args.output.mkdir(mode=0o700, parents=False)
        documents = render_documents(config, base)
        metadata = build_metadata(config, documents)
        for name, raw in {**documents, "bundle-metadata.json": canonical_metadata(metadata)}.items():
            path = args.output / name
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as output:
                output.write(raw)
                output.flush()
                os.fsync(output.fileno())
        print(f"Rendered strict {metadata['bundleVersion']} bundle: {args.output}")
        print("COMMISSIONING NO-GO: RAM cannot enforce create-only/CAS for oss:PutObject.")
        return 0
    except (OSError, PolicyError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
