package com.uten.imp.support;

import org.springframework.jdbc.core.JdbcTemplate;

/** Actual migrated read dependencies for query-only fixtures, never a posting fixture. */
public final class FinanceReportProjectionSchema {
    private FinanceReportProjectionSchema() { }

    public static void assetReports(JdbcTemplate db) {
        missing(db,"fixed_assets","deferred_expenses","finance_asset_books","finance_asset_categories",
                "finance_deferral_schedule_versions","finance_deferral_schedule_lines","finance_asset_posting_runs",
                "finance_asset_posting_lines","fa_depreciation_log","da_amortization_log","gl_vouchers","gl_entries",
                "finance_asset_template_metadata","finance_asset_opening_groups","finance_asset_opening_members",
                "finance_asset_opening_entry_claims","finance_asset_template_history","finance_template_sources",
                "payment_styles","finance_gl_opening_baselines","finance_accounting_import_batches",
                "finance_gl_period_versions","finance_accounting_period_coverage","finance_gl_voucher_evidence");
        db.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_finance_gl_voucher_is_booked",
                "fn_finance_balance_asof_complete","fn_finance_style_balance_asof",
                "fn_finance_style_balance_evidence_fingerprint","fn_finance_asset_opening_group_valid");
        MigratedProjectionSchema.createCurrentViews(db,"v_finance_asset_posting_facts","v_finance_asset_report_facts");
    }

    public static void receivableClassifications(JdbcTemplate db) {
        missing(db,"finance_open_item_classification_batches","finance_open_item_classification_parts",
                "finance_receipt_classification_batches","finance_receipt_classification_parts",
                "finance_customer_offset_classification_batches","finance_customer_offset_classification_parts");
        MigratedProjectionSchema.createCurrentViews(db,"v_finance_open_item_classification_current",
                "v_finance_receipt_classification_current","v_finance_customer_offset_classification_current");
    }

    public static void trialBalance(JdbcTemplate db) {
        missing(db,"finance_chart_codes","finance_chart_code_styles","finance_gl_opening_baselines",
                "finance_accounting_import_batches");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_finance_gl_voucher_is_booked");
    }

    /** Read-only native/retained cash dependencies. Installs actual migrated validators, never a proof stub. */
    public static void supplierAdvanceReplay(JdbcTemplate db) {
        missing(db,"finance_payments","finance_payment_lines","finance_supplier_advances",
                "finance_supplier_advance_parts","finance_supplier_advance_applications","finance_supplier_advance_refunds",
                "ar_ap_ledger","legacy_finance_import_sources","legacy_migration_runs","gl_vouchers","gl_entries",
                "finance_reconciliations","finance_gl_entry_allocations","finance_native_cash_debt_parts",
                "finance_open_item_classification_batches","finance_open_item_classification_parts",
                "finance_payment_classification_batches","finance_payment_classification_parts",
                "finance_supplier_offset_classification_batches","finance_supplier_offset_classification_parts",
                "finance_supplier_advance_target_classification_batches","finance_supplier_advance_target_classification_parts");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_business_decimal_from_integer",
                "fn_business_exact_divide_with_policy","fn_business_exact_divide","fn_financial_book_part",
                "fn_is_verified_legacy_opening_target");
        MigratedProjectionSchema.createCurrentViews(db,"v_payment_v2_expected_gl_entries_before_v1009",
                "v_payment_v2_expected_gl_entries","v_finance_open_item_classification_current",
                "v_finance_payment_classification_current","v_finance_supplier_offset_classification_current",
                "v_finance_supplier_advance_target_classification_current","v_finance_supplier_advance_target_parts_effective");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_assert_supplier_advance","fn_assert_payment_v2_terminal",
                "fn_finance_supplier_advance_replayable");
        MigratedProjectionSchema.createCurrentViews(db,"v_finance_supplier_advance_ap_events","v_finance_supplier_advance_asset_events");
    }

    private static void missing(JdbcTemplate db,String... tables) {
        for(String table:tables) {
            if(!Boolean.TRUE.equals(db.queryForObject("SELECT to_regclass(?) IS NOT NULL",Boolean.class,"public."+table)))
                MigratedProjectionSchema.createCurrentTables(db,table);
        }
    }
}
