#!/usr/bin/env python3
"""Profile legacy quantity/actual-weight evidence without exposing row data.

This utility is intentionally read-only.  It streams the exported pipe-delimited
CSV files and emits aggregate JSON only; business identifiers are used as
in-memory grouping keys and are never printed.

The result is evidence for a migration decision, not a migration itself.  In
particular, an empty weight in a source that never captured weight must not be
treated as proof that a goods item is quantity-only.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Iterable


ZERO = Decimal("0")


@dataclass(frozen=True)
class Source:
    file_name: str
    header_file_name: str
    operation_family: str
    goods_field: str
    bill_field: str
    qty_field: str
    weight_field: str
    unit_field: str | None


SOURCES: tuple[Source, ...] = (
    Source("purchase_receipt_items.csv", "purchase_receipts.csv", "PROCUREMENT", "goods_legacy_id", "bill_legacy_id", "qty", "weight", "unit_legacy_id"),
    Source("purchase_return_items.csv", "purchase_returns.csv", "PROCUREMENT", "goods_legacy_id", "bill_legacy_id", "qty", "weight", "unit_legacy_id"),
    Source("stock_other_in_i.csv", "stock_other_in_m.csv", "WAREHOUSE", "goods_legacy_id", "bill_legacy_id", "qty", "weight", "unit_legacy_id"),
    Source("stock_other_out_i.csv", "stock_other_out_m.csv", "WAREHOUSE", "goods_legacy_id", "bill_legacy_id", "qty", "weight", "unit_legacy_id"),
    Source("stock_transfer_i.csv", "stock_transfer_m.csv", "WAREHOUSE", "goods_legacy_id", "bill_legacy_id", "qty", "weight", "unit_legacy_id"),
    Source("stock_draw_i.csv", "stock_draw_m.csv", "WAREHOUSE", "goods_legacy_id", "bill_legacy_id", "qty", "weight", "unit_legacy_id"),
    Source("stock_wdraw_i.csv", "stock_wdraw_m.csv", "WAREHOUSE", "goods_legacy_id", "bill_legacy_id", "qty", "weight", "unit_legacy_id"),
    Source("stock_finished_in_i.csv", "stock_finished_in_m.csv", "WAREHOUSE", "goods_legacy_id", "bill_legacy_id", "qty", "weight", "unit_legacy_id"),
    Source("stock_finished_out_i.csv", "stock_finished_out_m.csv", "WAREHOUSE", "goods_legacy_id", "bill_legacy_id", "qty", "weight", "unit_legacy_id"),
    Source("sales_shipment_items.csv", "sales_shipments.csv", "SALES", "goods_legacy", "bill_legacy", "qty", "weight", "unit_legacy"),
    Source("sales_return_items.csv", "sales_returns.csv", "SALES", "goods_legacy", "bill_legacy", "qty", "weight", "unit_legacy"),
    Source("sales_other_shipment_items.csv", "sales_other_shipments.csv", "SALES", "goods_legacy", "bill_legacy", "qty", "weight", "unit_legacy"),
    Source("subcontract_in_i.csv", "subcontract_in_m.csv", "SUBCONTRACT", "goods_legacy_id", "bill_legacy_id", "qty", "weight", "unit_legacy_id"),
    Source("subcontract_sout_i.csv", "subcontract_sout_m.csv", "SUBCONTRACT", "goods_legacy_id", "bill_legacy_id", "qty", "weight", "unit_legacy_id"),
    Source("subcontract_withdraw_i.csv", "subcontract_withdraw_m.csv", "SUBCONTRACT", "goods_legacy_id", "bill_legacy_id", "qty", "weight", "unit_legacy_id"),
    Source("subcontract_swithdraw_i.csv", "subcontract_swithdraw_m.csv", "SUBCONTRACT", "goods_legacy_id", "bill_legacy_id", "qty", "weight", "unit_legacy_id"),
    Source("subcontract_swaste_i.csv", "subcontract_swaste_m.csv", "SUBCONTRACT", "goods_legacy_id", "bill_legacy_id", "qty", "weight", "unit_legacy_id"),
    Source("production_daily_report_items.csv", "production_daily_reports.csv", "PRODUCTION", "goods_legacy_id", "report_legacy_id", "qty", "weight", "unit_legacy_id"),
)


def decimal_or_zero(value: str | None) -> Decimal:
    text = (value or "").strip()
    if not text:
        return ZERO
    try:
        return Decimal(text)
    except InvalidOperation:
        return ZERO


def present(value: Decimal) -> bool:
    return value != ZERO


def rows(path: Path) -> Iterable[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        yield from csv.DictReader(handle, delimiter="|")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def profile_authority(data_dir: Path) -> dict[str, object]:
    manifest_path = data_dir / "export_manifest.json"
    checksum_path = data_dir / "export_manifest.sha256"
    if not manifest_path.is_file() or not checksum_path.is_file():
        return {
            "authoritative": False,
            "reason": "FORMAT3_MANIFEST_OR_CHECKSUM_MISSING",
        }
    try:
        manifest = json.loads(
            manifest_path.read_text(encoding="utf-8-sig")
        )
        if (
            manifest.get("formatVersion") != 3
            or manifest.get("target") != "All"
            or manifest.get("consistency")
            != "serializable-read-transaction"
            or manifest.get("offlineBackupRequired") is not True
        ):
            raise ValueError("MANIFEST_AUTHORITY_FIELDS_INVALID")
        if not re.fullmatch(
            r"[0-9a-f]{64}",
            str(manifest.get("sourceBackupSha256", "")),
        ):
            raise ValueError("SOURCE_BACKUP_DIGEST_INVALID")
        if not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9._:-]{2,127}",
            str(manifest.get("approvalReference", "")),
        ):
            raise ValueError("APPROVAL_REFERENCE_INVALID")
        if not re.fullmatch(
            r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})",
            str(manifest.get("repositoryCommit", "")),
        ):
            raise ValueError("REPOSITORY_COMMIT_INVALID")

        checksum_rows: dict[str, str] = {}
        for line in checksum_path.read_text(encoding="ascii").splitlines():
            match = re.fullmatch(
                r"([0-9a-f]{64}) \*([A-Za-z0-9][A-Za-z0-9_.-]*[.]csv)",
                line,
            )
            if match is None or match.group(2) in checksum_rows:
                raise ValueError("CHECKSUM_INVENTORY_INVALID")
            checksum_rows[match.group(2)] = match.group(1)

        records = manifest.get("files")
        if not isinstance(records, list):
            raise ValueError("MANIFEST_FILE_INVENTORY_INVALID")
        manifest_rows: dict[str, dict[str, object]] = {}
        for record in records:
            if not isinstance(record, dict):
                raise ValueError("MANIFEST_FILE_RECORD_INVALID")
            name = record.get("file")
            if (
                not isinstance(name, str)
                or name in manifest_rows
                or not re.fullmatch(
                    r"[A-Za-z0-9][A-Za-z0-9_.-]*[.]csv",
                    name,
                )
            ):
                raise ValueError("MANIFEST_FILE_RECORD_INVALID")
            manifest_rows[name] = record
        if set(manifest_rows) != set(checksum_rows):
            raise ValueError("MANIFEST_CHECKSUM_INVENTORY_DRIFT")
        for name, record in manifest_rows.items():
            path = data_dir / name
            if not path.is_file() or path.is_symlink():
                raise ValueError("MANIFEST_FILE_MISSING")
            digest = sha256_file(path)
            if (
                digest != record.get("sha256")
                or digest != checksum_rows[name]
                or path.stat().st_size != record.get("bytes")
            ):
                raise ValueError("MANIFEST_FILE_DIGEST_DRIFT")
        return {
            "authoritative": True,
            "format_version": 3,
            "target": "All",
            "manifest_sha256": sha256_file(manifest_path),
            "repository_commit": str(
                manifest["repositoryCommit"]
            ).lower(),
        }
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        return {
            "authoritative": False,
            "reason": str(error) or error.__class__.__name__,
        }


def shape(qty: Decimal, weight: Decimal) -> str:
    has_qty = present(qty)
    has_weight = present(weight)
    if has_qty and has_weight:
        return "quantity_and_weight"
    if has_qty:
        return "quantity_only"
    if has_weight:
        return "weight_without_quantity"
    return "neither"


def goods_shape(counter: Counter[str]) -> str:
    observed = {
        key for key in ("quantity_only", "quantity_and_weight", "weight_without_quantity")
        if counter[key] > 0
    }
    if not observed:
        return "no_evidence"
    if observed == {"quantity_only"}:
        return "quantity_only"
    if observed == {"quantity_and_weight"}:
        return "quantity_and_weight"
    if observed == {"weight_without_quantity"}:
        return "weight_without_quantity"
    return "mixed"


def coverage_bucket(counter: Counter[str]) -> str:
    quantity_rows = counter["quantity_only"] + counter["quantity_and_weight"]
    if quantity_rows == 0:
        return "no_quantity_observation"
    coverage = counter["quantity_and_weight"] / quantity_rows
    if coverage == 0:
        return "0%"
    if coverage < 0.05:
        return ">0%-<5%"
    if coverage < 0.25:
        return "5%-<25%"
    if coverage < 0.75:
        return "25%-<75%"
    if coverage < 0.95:
        return "75%-<95%"
    if coverage < 1:
        return "95%-<100%"
    return "100%"


def profile_sources(data_dir: Path) -> dict[str, object]:
    source_stats: dict[str, dict[str, object]] = {}
    new_aggregate = lambda: {
        "shapes": Counter(),
        "documents": set(),
        "weight_documents": set(),
        "weight_days": set(),
    }
    by_goods_all: dict[str, dict[str, object]] = defaultdict(new_aggregate)
    by_family_goods: dict[str, dict[str, dict[str, object]]] = defaultdict(
        lambda: defaultdict(new_aggregate)
    )

    for source in SOURCES:
        path = data_dir / source.file_name
        header_path = data_dir / source.header_file_name
        stats: Counter[str] = Counter()
        unit_ids: set[str] = set()
        if not path.exists() or not header_path.exists():
            source_stats[source.file_name] = {"missing_file": True}
            continue
        headers: dict[str, tuple[str, str, str]] = {}
        for header in rows(header_path):
            legacy_id = (header.get("legacy_id") or "").strip()
            if legacy_id:
                headers[legacy_id] = (
                    (header.get("status") or "").strip(),
                    (header.get("cancel_bit") or "").strip().lower(),
                    (header.get("bill_date") or "").strip(),
                )
        for row in rows(path):
            qty = decimal_or_zero(row.get(source.qty_field))
            weight = decimal_or_zero(row.get(source.weight_field))
            row_shape = shape(qty, weight)
            stats["rows"] += 1
            bill_id = (row.get(source.bill_field) or "").strip()
            header = headers.get(bill_id)
            if header is None:
                stats["missing_header"] += 1
                continue
            status, cancel_bit, bill_date = header
            if status != "1" or cancel_bit in {"true", "1", "yes"}:
                stats["excluded_not_active_approved"] += 1
                continue
            stats["approved_rows"] += 1
            stats[f"approved_{row_shape}"] += 1
            if qty < ZERO:
                stats["negative_qty"] += 1
            if weight < ZERO:
                stats["negative_weight"] += 1
            unit = (row.get(source.unit_field) or "").strip() if source.unit_field else ""
            if unit and unit != "0":
                unit_ids.add(unit)
            elif present(qty):
                stats["quantity_rows_missing_unit"] += 1

            goods_id = (row.get(source.goods_field) or "").strip()
            if not goods_id or row_shape == "neither":
                continue
            document_key = f"{source.file_name}:{bill_id}"
            for aggregate in (
                by_goods_all[goods_id],
                by_family_goods[source.operation_family][goods_id],
            ):
                shapes = aggregate["shapes"]
                documents = aggregate["documents"]
                weight_documents = aggregate["weight_documents"]
                weight_days = aggregate["weight_days"]
                assert isinstance(shapes, Counter)
                assert isinstance(documents, set)
                assert isinstance(weight_documents, set)
                assert isinstance(weight_days, set)
                shapes[row_shape] += 1
                documents.add(document_key)
                if present(weight):
                    weight_documents.add(document_key)
                    if bill_date:
                        weight_days.add(bill_date)

        qty_observations = (
            stats["approved_quantity_only"]
            + stats["approved_quantity_and_weight"]
        )
        stats_json: dict[str, object] = {
            key: stats[key]
            for key in (
                "rows",
                "approved_rows",
                "approved_quantity_only",
                "approved_quantity_and_weight",
                "approved_weight_without_quantity",
                "approved_neither",
                "excluded_not_active_approved",
                "missing_header",
                "negative_qty",
                "negative_weight",
                "quantity_rows_missing_unit",
            )
        }
        stats_json["distinct_nonzero_units"] = len(unit_ids)
        stats_json["weight_coverage_of_quantity_rows_pct"] = (
            round(
                100 * stats["approved_quantity_and_weight"] / qty_observations,
                4,
            )
            if qty_observations else None
        )
        source_stats[source.file_name] = stats_json

    def summarize_goods(
        grouped: dict[str, dict[str, object]],
    ) -> dict[str, object]:
        modes: Counter[str] = Counter()
        coverage: Counter[str] = Counter()
        observations: Counter[str] = Counter()
        candidates: Counter[str] = Counter()
        for aggregate in grouped.values():
            counter = aggregate["shapes"]
            assert isinstance(counter, Counter)
            modes[goods_shape(counter)] += 1
            coverage[coverage_bucket(counter)] += 1
            total = sum(counter.values())
            if total >= 10:
                observations[">=10"] += 1
            if total >= 5:
                observations[">=5"] += 1
            if total >= 3:
                observations[">=3"] += 1
            if total >= 1:
                observations[">=1"] += 1
            weight_documents = aggregate["weight_documents"]
            weight_days = aggregate["weight_days"]
            assert isinstance(weight_documents, set)
            assert isinstance(weight_days, set)
            if counter["weight_without_quantity"] > 0:
                candidates["review_weight_without_quantity"] += 1
            elif len(weight_documents) >= 3 and len(weight_days) >= 2:
                candidates["legacy_dual_pattern_3_docs_2_days"] += 1
            elif len(weight_documents) >= 1:
                candidates["legacy_dual_pattern_provisional"] += 1
            else:
                candidates["no_positive_weight_signal"] += 1
        return {
            "distinct_goods": len(grouped),
            "goods_shapes": dict(sorted(modes.items())),
            "weight_coverage_buckets": dict(sorted(coverage.items())),
            "goods_by_minimum_observations": dict(sorted(observations.items())),
            "learning_candidates": dict(sorted(candidates.items())),
        }

    return {
        "sources": source_stats,
        "all_physical_sources": summarize_goods(by_goods_all),
        "operation_families": {
            family: summarize_goods(grouped)
            for family, grouped in sorted(by_family_goods.items())
        },
    }


def profile_stock_goods(data_dir: Path) -> dict[str, object]:
    path = data_dir / "stock_goods.csv"
    if not path.exists():
        return {"missing_file": True}
    stats: Counter[str] = Counter()
    goods_fact: dict[str, Counter[str]] = defaultdict(Counter)
    by_dimension_year: dict[
        tuple[str, str, str, str], tuple[Decimal, Decimal]
    ] = {}
    for row in rows(path):
        qty = decimal_or_zero(row.get("qty"))
        fact_qty = decimal_or_zero(row.get("fact_qty"))
        weight = decimal_or_zero(row.get("weight"))
        fact_weight = decimal_or_zero(row.get("fact_weight"))
        stats["rows"] += 1
        stats[f"book_{shape(qty, weight)}"] += 1
        stats[f"fact_{shape(fact_qty, fact_weight)}"] += 1
        if fact_qty < ZERO:
            stats["negative_fact_qty"] += 1
        if fact_weight < ZERO:
            stats["negative_fact_weight"] += 1
        goods_id = (row.get("goods_legacy") or "").strip()
        if goods_id:
            goods_fact[goods_id][shape(fact_qty, fact_weight)] += 1
        dimension_year = (
            (row.get("stock_legacy") or "").strip(),
            goods_id,
            (row.get("color_legacy") or "").strip(),
            (row.get("year") or "").strip(),
        )
        previous_qty, previous_weight = by_dimension_year.get(
            dimension_year,
            (ZERO, ZERO),
        )
        by_dimension_year[dimension_year] = (
            previous_qty + fact_qty,
            previous_weight + fact_weight,
        )
    fact_shapes = Counter(goods_shape(counter) for counter in goods_fact.values())
    latest: dict[tuple[str, str, str], tuple[str, Decimal, Decimal]] = {}
    for (stock_id, goods_id, color_id, year), values in by_dimension_year.items():
        dimension = (stock_id, goods_id, color_id)
        current = latest.get(dimension)
        if current is None or year > current[0]:
            latest[dimension] = (year, values[0], values[1])
    latest_stats: Counter[str] = Counter()
    for _, qty, weight in latest.values():
        latest_stats["dimensions"] += 1
        if qty == ZERO and weight == ZERO:
            latest_stats["empty"] += 1
        if qty == ZERO and weight != ZERO:
            latest_stats["weight_without_quantity"] += 1
        if qty < ZERO:
            latest_stats["negative_quantity"] += 1
        if weight < ZERO:
            latest_stats["negative_weight"] += 1
        if qty * weight < ZERO:
            latest_stats["quantity_weight_sign_conflict"] += 1
        if qty != ZERO and weight == ZERO:
            latest_stats["quantity_with_unknown_weight"] += 1
        if qty > ZERO and weight > ZERO:
            latest_stats["positive_quantity_and_weight"] += 1
        if (
            (qty == ZERO and weight != ZERO)
            or qty < ZERO
            or weight < ZERO
            or qty * weight < ZERO
        ):
            latest_stats["distinct_quarantined_dimensions"] += 1
    return {
        **dict(sorted(stats.items())),
        "distinct_goods": len(goods_fact),
        "fact_goods_shapes": dict(sorted(fact_shapes.items())),
        "latest_year_dimensions": dict(sorted(latest_stats.items())),
    }


def profile_subcontract_issue_quantity(data_dir: Path) -> dict[str, int]:
    path = data_dir / "subcontract_sout_i.csv"
    if not path.exists():
        return {"missing_file": 1}
    stats: Counter[str] = Counter()
    for row in rows(path):
        qty = decimal_or_zero(row.get("qty"))
        alternate = decimal_or_zero(row.get("stqty"))
        stats["rows"] += 1
        if qty > ZERO:
            stats["qty_positive"] += 1
        if alternate > ZERO:
            stats["stqty_positive"] += 1
        if qty > ZERO and alternate > ZERO:
            if qty == alternate:
                stats["both_positive_equal"] += 1
            else:
                stats["both_positive_conflict"] += 1
        resolved = alternate if alternate > ZERO else qty
        if resolved > ZERO:
            stats["resolved_positive"] += 1
        else:
            stats["reject_no_positive_quantity"] += 1
    return dict(sorted(stats.items()))


def profile_goods_master(data_dir: Path) -> dict[str, object]:
    path = data_dir / "goods.csv"
    if not path.exists():
        return {"missing_file": True}
    numeric_hints = (
        "InitStock",
        "InitCount",
        "InitWeight",
        "KQTY",
        "KQTY2",
        "Pieces",
        "ZWeight",
        "MWeight",
    )
    stats: Counter[str] = Counter()
    unit_ids: set[str] = set()
    for row in rows(path):
        stats["rows"] += 1
        unit = (row.get("UnitID") or "").strip()
        if unit and unit != "0":
            stats["nonzero_unit"] += 1
            unit_ids.add(unit)
        else:
            stats["missing_unit"] += 1
        for field in numeric_hints:
            value = decimal_or_zero(row.get(field))
            if value != ZERO:
                stats[f"{field}_nonzero"] += 1
            if value < ZERO:
                stats[f"{field}_negative"] += 1
    return {**dict(sorted(stats.items())), "distinct_nonzero_units": len(unit_ids)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "data",
        help="Directory containing the exported legacy CSV files.",
    )
    parser.add_argument(
        "--require-authoritative",
        action="store_true",
        help=(
            "Fail unless a formatVersion 3 target=All manifest and every "
            "declared CSV digest are valid."
        ),
    )
    args = parser.parse_args()
    data_dir = args.data_dir.resolve()
    authority = profile_authority(data_dir)
    if args.require_authoritative and not authority["authoritative"]:
        raise SystemExit(
            "authoritative legacy export required: "
            + str(authority.get("reason", "UNKNOWN"))
        )
    result = {
        "schema_version": 1,
        "privacy": "aggregate_only_no_business_identifiers",
        "data_directory": str(data_dir),
        "authority": authority,
        "goods_master": profile_goods_master(data_dir),
        "stock_goods": profile_stock_goods(data_dir),
        "subcontract_issue_quantity": profile_subcontract_issue_quantity(
            data_dir
        ),
        "transaction_evidence": profile_sources(data_dir),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
