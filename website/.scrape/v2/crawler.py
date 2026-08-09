from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from legacy_site.config import DEFAULT_BASE_URL, RetrySettings
from legacy_site.fixture_site import run_fixture_smoke
from legacy_site.runner import CrawlOptions, LegacyCrawler
from legacy_site.validation import validate_output


HERE = Path(__file__).resolve().parent


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Recoverable GET-only crawler for the legacy UTEN public website"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    crawl = subparsers.add_parser("crawl", help="crawl public content into a resumable output")
    crawl.add_argument("--output", type=Path, default=HERE / "output")
    crawl.add_argument("--base-url", default=DEFAULT_BASE_URL)
    crawl.add_argument("--locales", default="zh,en", help="comma-separated zh,en")
    crawl.add_argument("--concurrency", type=int, choices=range(2, 5), default=3)
    crawl.add_argument("--attempts", type=int, default=4, help="total attempts per GET")
    crawl.add_argument("--timeout-seconds", type=float, default=20)
    crawl.add_argument("--throttle-ms", type=float, default=350)
    crawl.add_argument("--max-product-list-pages", type=int)
    crawl.add_argument("--max-details-per-locale", type=int)
    crawl.add_argument("--max-news-list-pages", type=int)
    crawl.add_argument("--max-static-pages-per-locale", type=int)
    crawl.add_argument("--no-media", action="store_true")
    crawl.add_argument("--no-resume", action="store_true")
    crawl.add_argument(
        "--allow-test-origin",
        action="store_true",
        help="allow an HTTP loopback base URL; never permits arbitrary external hosts",
    )

    validate = subparsers.add_parser("validate", help="recompute structural and hash checks")
    validate.add_argument("--output", type=Path, default=HERE / "output")
    expectation = validate.add_mutually_exclusive_group()
    expectation.add_argument("--expect-full", action="store_true")
    expectation.add_argument("--expect-partial", action="store_true")

    smoke = subparsers.add_parser("smoke", help="run the complete pipeline against a local fixture")
    smoke.add_argument("--output", type=Path)
    smoke.add_argument("--keep-output", action="store_true")
    return parser


def _run_crawl(args: argparse.Namespace) -> int:
    locales = tuple(item.strip() for item in args.locales.split(",") if item.strip())
    options = CrawlOptions(
        output_dir=args.output,
        base_url=args.base_url,
        locales=locales,
        concurrency=args.concurrency,
        retry_settings=RetrySettings(
            retries=args.attempts,
            timeout_seconds=args.timeout_seconds,
            throttle_seconds=args.throttle_ms / 1000,
        ),
        resume=not args.no_resume,
        download_media=not args.no_media,
        max_product_list_pages=args.max_product_list_pages,
        max_details_per_locale=args.max_details_per_locale,
        max_news_list_pages=args.max_news_list_pages,
        max_static_pages_per_locale=args.max_static_pages_per_locale,
        allow_test_origin=args.allow_test_origin,
    )
    catalog, media, qa = LegacyCrawler(options).run()
    print(
        json.dumps(
            {
                "status": qa["status"],
                "output": str(options.output_dir.resolve()),
                "products": qa["summary"]["products"],
                "news": qa["summary"]["news"],
                "mediaAssetsByHash": len(media["assets"]),
                "mediaFailures": len(media["failures"]),
                "fullRequested": catalog["scope"]["fullRequested"],
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return {"pass": 0, "warn": 2, "fail": 1}[qa["status"]]


def _run_validate(args: argparse.Namespace) -> int:
    expectation = True if args.expect_full else (False if args.expect_partial else None)
    report = validate_output(args.output, expect_full=expectation)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return {"pass": 0, "warn": 2, "fail": 1}[report["status"]]


def _run_smoke(args: argparse.Namespace) -> int:
    result = run_fixture_smoke(args.output, keep_output=args.keep_output or bool(args.output))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["status"] == "pass" else 1


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "crawl":
        return _run_crawl(args)
    if args.command == "validate":
        return _run_validate(args)
    if args.command == "smoke":
        return _run_smoke(args)
    raise AssertionError(args.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Interrupted; checkpoint has been preserved for --resume.", file=sys.stderr)
        raise SystemExit(130)
