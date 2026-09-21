#!/usr/bin/env python3
"""Persist source/target row reconciliation for every implemented document loader.

Core master/UUID checks remain the separate 23-item SQL contract. These checks
make a dropped document or line fatal; amount/quantity/source sign-off remains
an additional acceptance requirement, not something a row count can prove.
"""
import json
import runpy
import pathlib
import sys
import uuid


def document_queries():
    queries = {}
    for source, target in {
        "goods_bom": "goods_bom_items", "hr_workers": "employees",
        "purchase_applications": "purchase_requests", "purchase_application_items": "purchase_request_items",
        "purchase_orders": "purchase_orders", "purchase_order_items": "purchase_order_items",
        "purchase_receipts": "purchase_receipts", "purchase_receipt_items": "purchase_receipt_items",
        "purchase_returns": "purchase_returns", "purchase_return_items": "purchase_return_items",
        **{name: name for name in ["sales_quotes", "sales_quote_items", "sales_orders", "sales_order_items",
            "sales_order_cost_items", "sales_shipments", "sales_shipment_items", "sales_other_shipments",
            "sales_other_shipment_items", "sales_returns", "sales_return_items", "production_plans",
            "production_plan_items", "production_plan_costs"]},
        "m_acc": "accounts", "m_get": "finance_receipts", "m_paid": "finance_payments",
        "m_dpaid": "finance_expenses", "m_dpaid_item": "finance_expense_items",
        "m_oget": "finance_other_incomes", "m_oget_item": "finance_other_income_items",
        "m_allcheck": "finance_reconciliations",
    }.items():
        queries[source + ".csv"] = (target, f"SELECT count(*) FROM {target} WHERE legacy_id IS NOT NULL")
    for source, target in {
        "order": "orders", "order_cost": "order_cost_items", "in": "receipts",
        "sout": "material_issues", "withdraw": "returns", "swithdraw": "material_returns", "swaste": "wastes",
    }.items():
        if source == "order_cost":
            queries["subcontract_order_cost_i.csv"] = ("subcontract_order_cost_items",
                "SELECT count(*) FROM subcontract_order_cost_items WHERE legacy_id IS NOT NULL")
            continue
        queries[f"subcontract_{source}_m.csv"] = (f"subcontract_{target}",
                f"SELECT count(*) FROM subcontract_{target} WHERE legacy_id IS NOT NULL")
        item_target = target[:-1] + "_items"
        queries[f"subcontract_{source}_i.csv"] = (f"subcontract_{item_target}",
                f"SELECT count(*) FROM subcontract_{item_target} WHERE legacy_id IS NOT NULL")
    for source in ["transfer", "other_in", "other_out", "draw", "wdraw", "finished_in", "finished_out", "check"]:
        queries[f"stock_{source}_m.csv"] = ("stock_documents",
                f"SELECT count(*) FROM stock_documents WHERE legacy_id IS NOT NULL AND doc_type='{source.upper()}'")
        queries[f"stock_{source}_i.csv"] = ("stock_document_items",
                "SELECT count(*) FROM stock_document_items i JOIN stock_documents d ON d.id=i.doc_id "
                f"WHERE i.legacy_id IS NOT NULL AND d.doc_type='{source.upper()}'")
    for source in ["m_in", "m_out"]:
        queries[source + ".csv"] = ("ar_ap_ledger",
                f"SELECT count(*) FROM ar_ap_ledger WHERE legacy_source='{source[0].upper() + source[1:]}' AND legacy_id IS NOT NULL")
    return queries


def main():
    manifest_path, run_id = sys.argv[1:]
    uuid.UUID(run_id)
    records = {record["file"]: record for record in json.loads(pathlib.Path(manifest_path).read_text(encoding="utf-8-sig"))["files"]}
    print("CREATE TEMP TABLE bootstrap_module_checks(source text, target text, expected bigint, actual bigint, excluded bigint) ON COMMIT DROP;")
    for source, (target, query) in document_queries().items():
        expected = records[source]["rows"]
        if not isinstance(expected, int) or isinstance(expected, bool) or expected < 0:
            raise ValueError("invalid source row count")
        excluded = "(SELECT count(*) FROM bootstrap_bom_exclusions)" if source == "goods_bom.csv" else "0"
        print(f"INSERT INTO bootstrap_module_checks SELECT '{source}', '{target}', {expected}, ({query}), {excluded};")
    emit_master_identity_checks()
    print("SELECT * FROM bootstrap_module_checks WHERE expected <> actual + excluded;")
    print("""DO $$ BEGIN
        IF EXISTS (SELECT 1 FROM bootstrap_module_checks WHERE expected <> actual + excluded) THEN
            RAISE EXCEPTION 'document source/target row reconciliation failed';
        END IF;
    END; $$;
    UPDATE legacy_migration_runs SET reconciliation_summary = reconciliation_summary || jsonb_build_object(
        'moduleRowChecks', (SELECT jsonb_agg(jsonb_build_object(
            'source', source, 'target', target, 'expected', expected, 'actual', actual,
            'excluded', excluded, 'passed', expected = actual + excluded)
            ORDER BY source) FROM bootstrap_module_checks), 'moduleRowChecksPassed', true,
        'masterIdentityChecksPassed', true,
        'historicalAnchors', (SELECT COALESCE(jsonb_agg(to_jsonb(anchor) ORDER BY target_table,legacy_id),'[]'::jsonb)
            FROM bootstrap_verified_anchors anchor),
        'bomExclusions', (SELECT COALESCE(jsonb_agg(to_jsonb(exclusion) ORDER BY source_legacy_id),'[]'::jsonb)
            FROM bootstrap_bom_exclusions exclusion))
    WHERE run_id = current_setting('uten.bootstrap_run_id')::uuid;
    """)


def emit_master_identity_checks():
    # Load only the exact helper already bound to this reviewed candidate. Do
    # not add the working directory to Python's isolated module search path.
    authority = runpy.run_path(str(pathlib.Path(__file__).with_name("prepare_source_authority.py")), run_name="source_authority")
    markers = {
        "goods": "master.auto_created AND master.code='LEGACY-G-' || master.legacy_id",
        "units": "master.code='LEGACY-U-' || master.legacy_id",
        "colors": "master.code='LEGACY-C-' || master.legacy_id",
        "warehouses": "master.auto_created AND master.code='LEGACY-W-' || master.legacy_id",
        "currencies": "master.auto_created AND master.code='LEGACY-CUR-' || master.legacy_id",
        "clients": "master.status='禁用' AND master.code IN ('LEGACY-CL-' || master.legacy_id, 'LEGACY-FIN-CL-' || master.legacy_id)",
        "suppliers": "master.status='禁用' AND master.code IN ('LEGACY-S-' || master.legacy_id, 'LEGACY-FIN-SP-' || master.legacy_id)",
    }
    print("""CREATE TEMP TABLE bootstrap_identity_failures(target_table text,legacy_id integer,reason text) ON COMMIT DROP;
    CREATE TEMP TABLE bootstrap_verified_anchors(target_table text,target_id uuid,legacy_id integer,
        source_file text,source_row_id text,source_column text,source_row_number integer,reference_count bigint) ON COMMIT DROP;""")
    for table in authority["MASTER_SOURCES"].values():
        marker = markers.get(table, "false")
        print(f"""INSERT INTO bootstrap_identity_failures
            SELECT '{table}', source.legacy_id, 'SOURCE_ID_MISSING'
            FROM bootstrap_source_master_ids source LEFT JOIN {table} master ON master.legacy_id=source.legacy_id
            WHERE source.target_table='{table}' AND master.id IS NULL;
        INSERT INTO bootstrap_identity_failures
            SELECT '{table}', master.legacy_id, 'UNPROVEN_EXTRA_IDENTITY'
            FROM {table} master
            LEFT JOIN bootstrap_source_master_ids source ON source.target_table='{table}' AND source.legacy_id=master.legacy_id
            LEFT JOIN bootstrap_legacy_reference_evidence evidence ON evidence.target_table='{table}' AND evidence.legacy_id=master.legacy_id
            WHERE master.legacy_id IS NOT NULL AND master.legacy_id <> -1 AND source.legacy_id IS NULL
              AND (evidence.legacy_id IS NULL OR ({marker}) IS NOT TRUE);
        INSERT INTO bootstrap_verified_anchors
            SELECT '{table}', master.id, master.legacy_id, evidence.source_file, evidence.source_row_id,
                evidence.source_column,evidence.source_row_number,evidence.reference_count
            FROM {table} master JOIN bootstrap_legacy_reference_evidence evidence
                ON evidence.target_table='{table}' AND evidence.legacy_id=master.legacy_id
            LEFT JOIN bootstrap_source_master_ids source ON source.target_table='{table}' AND source.legacy_id=master.legacy_id
            WHERE source.legacy_id IS NULL AND ({marker});""")
    print("""SELECT * FROM bootstrap_identity_failures;
    DO $$ BEGIN IF EXISTS (SELECT 1 FROM bootstrap_identity_failures) THEN
        RAISE EXCEPTION 'source master identities and historical reference anchors do not reconcile';
    END IF; END; $$;""")


if __name__ == "__main__":
    main()
