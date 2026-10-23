package com.uten.imp.features.finance.gl;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.util.Arrays;
import java.util.EnumSet;
import java.util.stream.Collectors;

/**
 * Fixed report semantics expressed in original source categories/codes, independent of current display codes.
 * The database qualifies a source root using its successful import evidence. Explicit system posting roles
 * supply additional UUID anchors for the same financial meaning. Descendants follow actual UUID parent links;
 * overlapping anchors count each style once per report group. Ordinary same-code roots have no such authority.
 */
final class GlReportSourceScopes {
    private GlReportSourceScopes() {}

    enum Root {
        CASH("ACCOUNT", "101"), BANK("ACCOUNT", "102"), RECEIVABLES("ACCOUNT", "113", "AR_CONTROL"),
        OTHER_RECEIVABLES("ACCOUNT", "172"), OTHER_RECEIVABLES_ALTERNATE("ACCOUNT", "173"),
        INVENTORY("ACCOUNT", "123", "INVENTORY_ASSET"), PREPAID("ACCOUNT", "139"), FIXED_ASSETS("ACCOUNT", "151"),
        PAYABLES("LIABILITY", "203", "AP_CONTROL"), TAX_PAYABLE("LIABILITY", "221"),
        OTHER_PAYABLES("LIABILITY", "204"), OTHER_PAYABLES_ALTERNATE("LIABILITY", "205"),
        CAPITAL("EQUITY", "301"), RETAINED_PROFIT("EQUITY", "321"),
        MAIN_REVENUE("INCOME", "031", "SALES_REVENUE"), OTHER_REVENUE("INCOME", "032"),
        NON_OPERATING_REVENUE("INCOME", "033"), MAIN_COST("EXPENSE", "041", "SALES_COST"),
        OTHER_COST("EXPENSE", "042"), ADMIN_EXPENSE("EXPENSE", "043");

        final String category;
        final String sourceCode;
        final String postingRole;
        Root(String category, String sourceCode) {
            this(category, sourceCode, null);
        }
        Root(String category, String sourceCode, String postingRole) {
            this.category = category;
            this.sourceCode = sourceCode;
            this.postingRole = postingRole;
        }
    }

    private static String scope(Root... roots) {
        if (roots.length == 0) throw new IllegalArgumentException("report source roots must not be empty");
        String definitions = EnumSet.copyOf(Arrays.asList(roots)).stream()
                .map(root -> "('%s','%s','%s',%s)".formatted(root.name(), root.category, root.sourceCode,
                        root.postingRole == null ? "NULL" : "'" + root.postingRole + "'"))
                .collect(Collectors.joining(","));
        // Only enum constants enter SQL. Materialize the small root inventory before joining financial entries.
        return """
                WITH RECURSIVE report_root_definitions(root_key, category, source_code, posting_role) AS (VALUES %s),
                source_roots AS MATERIALIZED (
                    SELECT definition.root_key, style.id AS root_id, definition.category AS root_category
                    FROM report_root_definitions definition
                    JOIN payment_styles style ON style.category = definition.category
                         AND btrim(style.legacy_source_code) = definition.source_code AND style.parent_id IS NULL
                    WHERE public.fn_legacy_payment_style_source_root_matches(
                        style.id, definition.category, definition.source_code)
                ), role_roots AS MATERIALIZED (
                    SELECT definition.root_key, style.id AS root_id, definition.category AS root_category
                    FROM report_root_definitions definition
                    JOIN system_posting_style_roles authority ON authority.role_key = definition.posting_role
                    JOIN payment_styles style ON style.id = authority.style_id AND style.category = definition.category
                ), report_roots AS MATERIALIZED (
                    SELECT root_key, root_id, root_category FROM source_roots
                    UNION
                    SELECT root_key, root_id, root_category FROM role_roots
                ), report_style_scope(root_key, style_id, root_category) AS (
                    SELECT root_key, root_id, root_category FROM report_roots
                    UNION
                    SELECT scope.root_key, child.id, scope.root_category
                    FROM report_style_scope scope JOIN payment_styles child ON child.parent_id = scope.style_id
                )
                """.formatted(definitions);
    }

    /** Validate all fixed groups together, so a category-valid role cannot silently double count another group. */
    static void assertUnambiguous(EntityManager em) {
        var conflicts = NativeQueryResults.objectArrayRows(em.createNativeQuery(ambiguitySql()));
        if (conflicts.isEmpty()) return;
        Object[] conflict = conflicts.getFirst();
        String groups = Arrays.stream(((String) conflict[2]).split(","))
                .map(key -> rootLabel(Root.valueOf(key))).collect(Collectors.joining("、"));
        throw new ApiException(ErrorCode.CONFLICT, "总账报表配置冲突：科目「%s」（%s）同时属于%s，请核对科目层级和系统科目用途。"
                .formatted(conflict[1], conflict[0], groups));
    }

    static String ambiguitySql() {
        return scope(Root.values()) + """
                SELECT style.code, style.name, string_agg(DISTINCT scope.root_key, ',' ORDER BY scope.root_key)
                FROM report_style_scope scope JOIN payment_styles style ON style.id = scope.style_id
                GROUP BY style.id, style.code, style.name
                HAVING count(DISTINCT scope.root_key) > 1
                ORDER BY style.code, style.id LIMIT 1
                """;
    }

    private static String rootLabel(Root root) {
        return switch (root) {
            case CASH -> "现金";
            case BANK -> "银行存款";
            case RECEIVABLES -> "应收账款";
            case OTHER_RECEIVABLES, OTHER_RECEIVABLES_ALTERNATE -> "其他应收款";
            case INVENTORY -> "存货";
            case PREPAID -> "待摊费用";
            case FIXED_ASSETS -> "固定资产";
            case PAYABLES -> "应付账款";
            case TAX_PAYABLE -> "应交税费";
            case OTHER_PAYABLES, OTHER_PAYABLES_ALTERNATE -> "其他应付款";
            case CAPITAL -> "实收资本";
            case RETAINED_PROFIT -> "未分配利润";
            case MAIN_REVENUE -> "主营业务收入";
            case OTHER_REVENUE -> "其他业务收入";
            case NON_OPERATING_REVENUE -> "营业外收入";
            case MAIN_COST -> "主营业务成本";
            case OTHER_COST -> "其他业务成本";
            case ADMIN_EXPENSE -> "管理费用";
        };
    }

    static String balancesSql() {
        return scope(Root.values()) + """
                SELECT scope.root_key,
                       CASE WHEN scope.root_category IN ('LIABILITY','EQUITY','INCOME')
                            THEN -SUM(e.direction * e.amount) ELSE SUM(e.direction * e.amount) END
                FROM gl_entries e JOIN report_style_scope scope ON scope.style_id = e.style_id
                WHERE e.is_deleted = false AND e.entry_date <= :d
                GROUP BY scope.root_key, scope.root_category
                """;
    }

    static String monthlySql(Root... roots) {
        return scope(roots) + """
                SELECT EXTRACT(MONTH FROM e.entry_date)::int,
                       SUM(CASE WHEN :cat = 'INCOME' THEN -e.direction * e.amount ELSE e.direction * e.amount END)
                FROM gl_entries e
                JOIN payment_styles ps ON ps.id = e.style_id
                JOIN report_style_scope scope ON scope.style_id = ps.id
                WHERE e.is_deleted = false AND ps.category = :cat
                  AND e.entry_date BETWEEN :from AND :to
                GROUP BY 1
                """;
    }

    static String operatingBaseSql() {
        return scope(Root.MAIN_REVENUE, Root.OTHER_REVENUE) + """
                SELECT COALESCE(SUM(-e.direction * e.amount),0)
                FROM gl_entries e JOIN payment_styles ps ON ps.id = e.style_id
                JOIN report_style_scope scope ON scope.style_id = ps.id
                WHERE e.is_deleted = false AND ps.category = 'INCOME'
                  AND e.entry_date BETWEEN :from AND :to
                """;
    }

    static String adminSql() {
        return scope(Root.ADMIN_EXPENSE) + """
                SELECT EXTRACT(MONTH FROM entry.entry_date)::int, SUM(entry.direction * entry.amount)
                FROM gl_entries entry
                JOIN payment_styles style ON style.id = entry.style_id
                JOIN report_style_scope scope ON scope.style_id = style.id
                WHERE entry.is_deleted = FALSE AND style.category = 'EXPENSE'
                  AND NOT EXISTS (
                      SELECT 1 FROM finance_report_line_bindings binding
                      WHERE binding.binding_kind = 'STYLE' AND binding.style_id = style.id
                        AND binding.line_key IN (:excluded))
                  AND entry.entry_date BETWEEN :from AND :to
                GROUP BY 1
                """;
    }
}
