package com.uten.imp.features.finance.statement;

/** Exact dated category usage shared with database guards and all AP consumers. */
public final class FinanceClassificationCapacitySql {
    private FinanceClassificationCapacitySql() { }
    public static final String CURRENT_USAGE="""
        SELECT category,sum(amount_original) AS used_original,sum(book_local) AS used_local
        FROM v_finance_payable_category_consumption_events
        WHERE ledger_id=? AND(CAST(? AS uuid) IS NULL OR offset_id IS DISTINCT FROM CAST(? AS uuid)) GROUP BY category
        """;
    static final String SQL="SELECT ?::uuid AS ledger_id WHERE fn_finance_payable_classification_exceeds(?::uuid)";
}
