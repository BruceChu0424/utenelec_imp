package com.uten.imp.features.finance;

/** Shared source-bound opening amounts and replay window for reports and supplier statements. */
public final class LegacyOpeningBalanceSql {
    private LegacyOpeningBalanceSql() { }

    /** An explicit historical FX difference can prove book local; missing FX cannot mean zero. */
    public static String paymentBookLocal(String lineAlias) {
        identifier(lineAlias);
        return "COALESCE("+lineAlias+".applied_amount_local,CASE WHEN "+lineAlias
                +".amount_local IS NOT NULL AND "+lineAlias+".exchange_diff IS NOT NULL THEN "
                +lineAlias+".amount_local-"+lineAlias+".exchange_diff END)";
    }

    /** Native cash whose book effect cannot be reconstructed must not disappear inside SUM. */
    public static String unknownCashBook(boolean receipt,String headerAlias) {
        identifier(headerAlias);
        String table=receipt?"finance_receipt_lines":"finance_payment_lines";
        String parent=receipt?"receipt_id":"payment_id";
        String book=receipt?"book_line.applied_amount_local":paymentBookLocal("book_line");
        String link=" FROM "+table+" book_line WHERE book_line."+parent+"="+headerAlias
                +".id AND NOT COALESCE(book_line.is_deleted,false)";
        return "(EXISTS(SELECT 1"+link+" AND ("+book+") IS NULL) OR (NOT EXISTS(SELECT 1"
                +link+") AND "+headerAlias+".amount_local IS NULL))";
    }

    private static void identifier(String value) {
        if(!value.matches("[a-z][a-zA-Z0-9_]*")) throw new IllegalArgumentException("Invalid internal alias");
    }

    /** Consumers use the same ledger/opening aliases; proof identity is never inferred from bill numbers. */
    public static final String PROOF_JOIN = """
            LEFT JOIN legacy_finance_import_sources opening
              ON opening.run_id=ledger.legacy_import_run_id AND opening.target_id=ledger.id
             AND opening.target_table='ar_ap_ledger'
            """;

    public static String localAmount(String nativeExpression) {
        return initialAmount("amount_balance", nativeExpression);
    }

    public static String originalAmount(String nativeExpression) {
        return initialAmount("amount_balance_original", nativeExpression);
    }

    private static String initialAmount(String field, String nativeExpression) {
        return "CASE WHEN ledger.legacy_import_run_id IS NOT NULL THEN (opening.initial_state->>'"
                + field + "')::numeric ELSE (" + nativeExpression + ") END";
    }

    /** Caller supplies its query's internal date parameter, never user SQL. */
    public static String unreplayableCondition(String startParameter) {
        return unreplayableCondition(startParameter, true);
    }

    public static String unreplayableCondition(String startParameter, boolean requireOriginal) {
        if (!startParameter.matches("[a-z][a-zA-Z0-9]*")) throw new IllegalArgumentException("Invalid internal date parameter");
        return """
                ((ledger.legacy_id IS NOT NULL OR ledger.legacy_import_run_id IS NOT NULL) AND (
                    ledger.legacy_import_run_id IS NULL
                    OR opening.target_id IS NULL
                    OR ledger.legacy_source_resolution->>'snapshotAsOfUtc' IS NULL
                    OR ((ledger.legacy_source_resolution->>'snapshotAsOfUtc')::timestamptz
                        AT TIME ZONE 'Asia/Shanghai')::date >= :%s
                    OR opening.initial_state->>'amount_balance' IS NULL
                    %s))
                """.formatted(startParameter, requireOriginal ? "OR (" + unverifiedOriginalCondition() + ")" : "");
    }

    /** Local-currency reports can disclose this uncertainty without erasing a proved local balance. */
    public static String unverifiedOriginalCondition() {
        return """
                ledger.currency_id IS NULL OR ledger.amount_original IS NULL OR ledger.amount_balance_original IS NULL
                OR (ledger.legacy_import_run_id IS NOT NULL AND opening.initial_state->>'amount_balance_original' IS NULL)
                """;
    }
}
