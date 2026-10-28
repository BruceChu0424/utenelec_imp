package com.uten.imp.features.finance.report;

import com.uten.imp.common.util.SqlColumnSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/** Display-row conditions: apply only after the account's complete running balance window. */
final class AccountStatementColumnQuery {
    private AccountStatementColumnQuery() {}
    private static final Map<String, SqlColumnSearch.Field> FIELDS = Map.ofEntries(
            Map.entry("billDate", SqlColumnSearch.Field.instant("sort_bill_date")),
            Map.entry("settledDate", SqlColumnSearch.Field.instant("settled_date")),
            Map.entry("billNo", SqlColumnSearch.Field.text("bill_no")),
            Map.entry("checkNo", SqlColumnSearch.Field.text("check_no")),
            Map.entry("summary", SqlColumnSearch.Field.text("summary")),
            Map.entry("counterpartName", SqlColumnSearch.Field.text("counterpart_name")),
            Map.entry("source", SqlColumnSearch.Field.text("source")),
            Map.entry("inAmount", SqlColumnSearch.Field.decimal("in_amount")),
            Map.entry("outAmount", SqlColumnSearch.Field.decimal("out_amount")),
            Map.entry("balance", SqlColumnSearch.Field.decimal("balance")));
    private static final Set<String> SOURCES = Set.of("RECEIPT", "RECEIPT_FEE", "PAYMENT", "EXPENSE", "INCOME",
            "BANK_TRANSFER", "BALANCE_ADJUSTMENT", "SUPPLIER_CLAIM_RECEIPT");
    private static final Set<String> KINDS = Set.of("POSTING", "REVERSAL", "ADJUSTMENT");

    static SqlColumnSearch.Criteria criteria(Map<String, String> parameters) {
        Map<String, String> input = new LinkedHashMap<>();
        if (parameters != null) parameters.forEach((key, value) -> {
            if (key.startsWith("search.")) input.put(key.substring(7), value);
        });
        var search = SqlColumnSearch.criteria(input, FIELDS);
        StringBuilder predicate = new StringBuilder("(").append(search.predicate()).append(')');
        Map<String, Object> bindings = new LinkedHashMap<>(search.parameters());
        choice(parameters, "entryKind", "entry_kind", KINDS, predicate, bindings);
        choice(parameters, "sourceDocType", "source_doc_type", SOURCES, predicate, bindings);
        return new SqlColumnSearch.Criteria(predicate.toString(), Map.copyOf(bindings));
    }

    private static void choice(Map<String, String> input, String key, String expression, Set<String> allowed,
                               StringBuilder predicate, Map<String, Object> bindings) {
        String raw = input == null ? null : input.get(key);
        if (raw == null || raw.isBlank()) return;
        String value = raw.strip().toUpperCase(Locale.ROOT);
        if (!allowed.contains(value)) throw new ApiException(ErrorCode.VALIDATION_FAILED, "账户流水类型筛选无效");
        String parameter = "statement_" + key;
        predicate.append(" AND ").append(expression).append("=:").append(parameter);
        bindings.put(parameter, value);
    }
}
