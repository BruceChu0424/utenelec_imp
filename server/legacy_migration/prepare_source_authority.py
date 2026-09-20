#!/usr/bin/env python3
"""Produce exact master identities and reviewed historical-reference evidence.

The full coordinator has already verified the All export. Recheck each consumed
file's digest and row count here so reconciliation uses those same CSV bytes.
Only references that the corresponding loader actually uses to create missing
historical masters authorize an extra target identity. BOM-only references and
integer fields from unrelated namespaces never authorize a historical anchor.
"""
from __future__ import annotations

import csv
import datetime as dt
import hashlib
import json
import pathlib
import re
import sys
from collections.abc import Iterable


MASTER_SOURCES = {
    "goods_categories.csv": "material_categories",
    "mould_categories.csv": "mould_categories",
    "client_categories.csv": "client_categories",
    "supplier_categories.csv": "supplier_categories",
    "goods.csv": "goods", "mould.csv": "moulds", "client.csv": "clients",
    "supplier.csv": "suppliers", "color.csv": "colors", "unit.csv": "units",
    "currency.csv": "currencies", "warehouse.csv": "warehouses",
}


def reference_columns() -> dict[str, dict[str, str]]:
    """Mirror only the explicit historical INSERT candidates in reviewed loaders."""
    refs: dict[str, dict[str, str]] = {}

    def bind(files: Iterable[str], **columns: str) -> None:
        for name in files:
            refs.setdefault(name + ".csv", {}).update(columns)

    purchase = ["purchase_application_items", "purchase_order_items",
                "purchase_receipt_items", "purchase_return_items"]
    bind(purchase, goods_legacy_id="goods", unit_legacy_id="units", color_legacy_id="colors")
    bind(["purchase_applications", "purchase_receipts", "purchase_returns"], warehouse_legacy_id="warehouses")
    bind(["purchase_orders", "purchase_receipts", "purchase_returns"], currency_legacy_id="currencies", supplier_legacy_id="suppliers")

    stock = ["transfer", "other_in", "other_out", "draw", "wdraw", "finished_in", "finished_out", "check"]
    bind([f"stock_{name}_i" for name in stock], goods_legacy_id="goods", unit_legacy_id="units", color_legacy_id="colors")
    bind([f"stock_{name}_m" for name in stock], stock_legacy_id="warehouses", to_stock_legacy_id="warehouses")
    # A retained balance may outlive both the master and every O_* document.
    # Preserve its exact goods/color dimension as historical references too.
    bind(["stock_goods"], stock_legacy="warehouses", goods_legacy="goods", color_legacy="colors")

    sales_items = ["sales_quote_items", "sales_order_items", "sales_shipment_items",
                   "sales_other_shipment_items", "sales_return_items"]
    bind(sales_items, goods_legacy="goods", unit_legacy="units", color_legacy="colors")
    bind(["sales_order_cost_items"], goods_legacy="goods", alt_goods_legacy="goods", color_legacy="colors")
    bind(["sales_quotes", "sales_orders", "sales_shipments", "sales_other_shipments", "sales_returns"], client_legacy="clients")
    bind(["sales_shipments", "sales_other_shipments", "sales_returns"], warehouse_legacy="warehouses")
    bind(["sales_orders", "sales_shipments", "sales_other_shipments", "sales_returns"], cur_legacy="currencies")

    subcontract = ["ask", "application", "order", "in", "sout", "withdraw", "swithdraw", "swaste"]
    bind([f"subcontract_{name}_i" for name in subcontract], goods_legacy_id="goods", unit_legacy_id="units", color_legacy_id="colors")
    bind(["subcontract_order_cost_i"], goods_legacy_id="goods", m_goods_legacy_id="goods", color_legacy_id="colors", m_color_legacy_id="colors")
    bind(["subcontract_sout_i", "subcontract_swithdraw_i"], parent_goods_legacy_id="goods", parent_color_legacy_id="colors")
    bind([f"subcontract_{name}_m" for name in subcontract], supplier_legacy_id="suppliers")
    bind([f"subcontract_{name}_m" for name in ["in", "sout", "withdraw", "swithdraw", "swaste"]], warehouse_legacy_id="warehouses")
    bind([f"subcontract_{name}_m" for name in ["application", "order", "in", "withdraw"]], currency_legacy_id="currencies")

    bind(["production_plan_items", "production_plan_costs"], goods_legacy_id="goods", mgoods_legacy_id="goods", color_legacy_id="colors")
    bind(["production_plan_items"], unit_legacy_id="units")
    bind(["production_plan_costs"], mcolor_legacy_id="colors", supplier_legacy_id="suppliers")
    bind(["m_in", "m_get"], client_legacy_id="clients")
    bind(["m_out", "m_paid"], supplier_legacy_id="suppliers")
    return refs


REFERENCE_COLUMNS = reference_columns()


def digest(path: pathlib.Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def legacy_id(value: str | None, *, required: bool) -> int | None:
    if value is None or not value.strip():
        if required:
            raise ValueError("missing source legacy identity")
        return None
    if not re.fullmatch(r"-?[0-9]+", value.strip()):
        raise ValueError("legacy identity is not an exact integer")
    identity = int(value)
    if not -(2**31) <= identity < 2**31:
        raise ValueError("legacy identity exceeds the original integer domain")
    if identity == 0:
        if required:
            raise ValueError("zero is a reference sentinel, not a master identity")
        return None
    return identity


def source_rows(directory: pathlib.Path, name: str, record: dict, required: set[str]):
    path = directory / name
    expected_count = record.get("rows")
    expected_hash = record.get("sha256")
    if (type(expected_count) is not int or expected_count < 0
            or not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_hash)):
        raise ValueError(f"invalid reviewed file record: {name}")
    if path.is_symlink() or not path.is_file() or digest(path) != expected_hash:
        raise ValueError(f"source file differs from the reviewed manifest: {name}")
    count = 0
    with path.open(encoding="utf-8-sig", newline="") as source:
        reader = csv.DictReader(source, delimiter="|")
        headers = reader.fieldnames or []
        if len(headers) != len(set(headers)) or not required.issubset(headers):
            raise ValueError(f"source CSV identity columns differ from the loader: {name}")
        for count, row in enumerate(reader, 1):
            if None in row or any(value is None for value in row.values()):
                raise ValueError(f"source CSV row width mismatch: {name}:{count}")
            yield count, row
    if count != expected_count or digest(path) != expected_hash:
        raise ValueError(f"source row count or bytes changed while reading: {name}")


def collect(manifest_path: pathlib.Path) -> tuple[list[tuple], list[tuple]]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    if manifest.get("target") != "All" or manifest.get("formatVersion") != 4:
        raise ValueError("source authority requires a reviewed format-v4 All manifest")
    cutoff = str(manifest.get("sourceSnapshotAsOfUtc", ""))
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", cutoff):
        raise ValueError("source authority requires the approved snapshot cutoff")
    dt.datetime.fromisoformat(cutoff.replace("Z", "+00:00"))
    records = {}
    for record in manifest["files"]:
        name = record.get("file")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*[.]csv", name) or name in records:
            raise ValueError("manifest file identity is invalid or repeated")
        records[name] = record
    required_files = MASTER_SOURCES.keys() | REFERENCE_COLUMNS.keys()
    if not required_files <= records.keys():
        raise ValueError("All manifest is missing a reviewed master/reference source")
    directory = manifest_path.parent
    masters = {}
    for name, target in MASTER_SOURCES.items():
        for number, row in source_rows(directory, name, records[name], {"legacy_id"}):
            identity = legacy_id(row["legacy_id"], required=True)
            key = (target, identity)
            if key in masters:
                raise ValueError(f"duplicate source master identity: {name}:{number}")
            masters[key] = (target, identity, name, str(identity), number)

    references = {}
    for name, columns in sorted(REFERENCE_COLUMNS.items()):
        key_columns = {"stock_legacy", "goods_legacy", "color_legacy", "year"} if name == "stock_goods.csv" else {"legacy_id"}
        for number, row in source_rows(directory, name, records[name], set(columns) | key_columns):
            row_id = (json.dumps({key: row[key] for key in sorted(key_columns)}, separators=(",", ":"))
                      if name == "stock_goods.csv" else str(legacy_id(row["legacy_id"], required=True)))
            for column, target in columns.items():
                identity = legacy_id(row[column], required=False)
                if identity is None or (target, identity) in masters:
                    continue
                key = target, identity
                if key not in references:
                    references[key] = [target, identity, name, row_id, column, number, 0]
                references[key][-1] += 1
    return sorted(masters.values()), [tuple(references[key]) for key in sorted(references)]


def sql_literal(value: str | int) -> str:
    return str(value) if isinstance(value, int) else "'" + value.replace("'", "''") + "'"


def insert_rows(table: str, rows: list[tuple]) -> None:
    for offset in range(0, len(rows), 500):
        block = rows[offset:offset + 500]
        print(f"INSERT INTO {table} VALUES\n" + ",\n".join(
            "(" + ",".join(map(sql_literal, row)) + ")" for row in block) + ";")


def main() -> None:
    masters, references = collect(pathlib.Path(sys.argv[1]))
    print("""CREATE TEMP TABLE bootstrap_source_master_ids (
        target_table text NOT NULL, legacy_id integer NOT NULL, source_file text NOT NULL,
        source_row_id text NOT NULL, source_row_number integer NOT NULL CHECK(source_row_number>0),
        PRIMARY KEY(target_table,legacy_id)) ON COMMIT DROP;
CREATE TEMP TABLE bootstrap_legacy_reference_evidence (
        target_table text NOT NULL, legacy_id integer NOT NULL, source_file text NOT NULL,
        source_row_id text NOT NULL, source_column text NOT NULL,
        source_row_number integer NOT NULL CHECK(source_row_number>0),
        reference_count bigint NOT NULL CHECK(reference_count>0),
        PRIMARY KEY(target_table,legacy_id)) ON COMMIT DROP;""")
    insert_rows("bootstrap_source_master_ids", masters)
    insert_rows("bootstrap_legacy_reference_evidence", references)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, csv.Error) as error:
        print(f"Source authority rejected: {error}", file=sys.stderr)
        sys.exit(66)
