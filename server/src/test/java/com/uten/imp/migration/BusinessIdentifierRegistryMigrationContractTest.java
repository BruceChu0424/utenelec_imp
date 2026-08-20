package com.uten.imp.migration;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.mastercode.MasterCodePrefix;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class BusinessIdentifierRegistryMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/V279__global_business_identifier_registry.sql");
    private static final Pattern NAMESPACE_ROW = Pattern.compile(
            "\\('([A-Z][A-Z0-9_]*)',\\s*'(DOCUMENT|MASTER|SYSTEM)',\\s*'([A-Z0-9]+)'");

    @Test
    void everyDocumentEnumUsesItsExactDatabaseNamespaceAndPrefix() throws IOException {
        Map<String, String> namespaces = namespacePrefixes(registrySql());
        for (DocNumberPrefix prefix : DocNumberPrefix.values()) {
            assertEquals(prefix.code(), namespaces.get(prefix.name()),
                    () -> "Missing or drifted namespace for " + prefix.name());
        }
        assertEquals("SZ", namespaces.get("PRODUCTION_SUBPLAN"));
        assertEquals("QW", namespaces.get("STOCK_WASTE"));
        assertEquals("V", namespaces.get("VISITOR_ACCOUNT"));
        assertEquals("ZX", namespaces.get("PRODUCTION_EXECUTION_SEGMENT"));
        assertEquals(37, namespaceFamilyCount(sql(), "DOCUMENT"));
        assertEquals(2, namespaceFamilyCount(sql(), "SYSTEM"));
    }

    @Test
    void everyMasterDefaultPrefixIsReservedWithoutCreatingASecondVisitorOwner()
            throws IOException {
        Map<String, String> namespaces = namespacePrefixes(registrySql());
        Set<String> registeredPrefixes = Set.copyOf(namespaces.values());
        for (MasterCodePrefix prefix : MasterCodePrefix.values()) {
            assertTrue(registeredPrefixes.contains(prefix.code()),
                    () -> "Missing MasterCodePrefix reservation: " + prefix.name());
        }
        assertFalse(namespaces.containsKey("MASTER_VISITOR"),
                "VISITOR_ACCOUNT is the single V namespace owner");
        assertFalse(namespaces.containsKey("MASTER_PRODUCTION_EXECUTION_SEGMENT"),
                "PRODUCTION_EXECUTION_SEGMENT is the single ZX namespace owner");
    }

    @Test
    void migrationBuildsGlobalLifetimeAuthoritiesAndStrictWriteGuards()
            throws IOException {
        String sql = normalizedSql();
        for (String table : Set.of(
                "business_identifier_namespaces", "business_document_sequences",
                "production_product_no_sequences",
                "business_prefix_reservations", "business_prefix_reservation_members",
                "business_identifier_reservations",
                "business_identifier_reservation_members",
                "business_identifier_conflicts")) {
            assertTrue(sql.contains("create table " + table), table);
        }
        assertTrue(sql.contains("upper(btrim(normalized_prefix))"));
        assertTrue(sql.contains("upper(btrim(normalized_identifier))"));
        assertTrue(sql.contains("fn_guard_business_identifier_append_only"));
        assertTrue(sql.contains("app.business_identifier_legacy_import"));
        assertTrue(sql.contains("non-standard %s identifier rejected"));
        assertTrue(sql.contains(
                "v_raw_identifier_snapshot is distinct from v_normalized_identifier"));
        assertTrue(sql.contains("trg_business_namespace_prefix"));
        assertTrue(sql.contains("fn_claim_global_business_prefix"));
        assertTrue(sql.contains("business_identifier_namespaces_source_default_uq"),
                "Every source column has at most one null/default route");
        assertTrue(sql.contains("business_identifier_namespaces_source_discriminator_uq"));
        assertTrue(sql.contains("current_setting('app.master_code_audit_stage'"));
        assertTrue(sql.contains("trg_global_identifier_production_plan_items"));
        assertTrue(sql.contains("'production_plan_item', 'production_plan_items', plan_id"));
        assertTrue(sql.contains("fn_allocate_production_product_no"));
        assertTrue(sql.contains("repeat('0', greatest(3 - char_length(v_sequence::text), 0))"));
        assertFalse(sql.contains("tg_op = 'insert' and legacy_identity is not null"));
        assertFalse(sql.contains(
                "v_legacy_import_mode := v_legacy_identity is not null"));
        assertFalse(sql.contains("\n or same_legacy_member\n"),
                "Reusing a legacy shadow must not grant a generic online bypass");
        assertTrue(sql.contains(
                "or (p_allow_same_logical_owner and same_legacy_member)"));
        assertTrue(sql.contains(
                "base_domain = 'finance_asset_category' and tg_op = 'insert'"),
                "Only the versioned finance asset category chain may share a logical owner");
        assertTrue(sql.contains("'business_document_sequences'"));
        assertFalse(sql.contains("ar_ap_ledger"));
        assertFalse(sql.contains("gl_vouchers"));
        assertFalse(sql.contains("normalized_prefix like"),
                "Prefix containment must be allowed; only exact tokens conflict");
    }

    @Test
    void everyAuthoritativeHeaderHasAnInsertAndImmutabilityTrigger()
            throws IOException {
        String sql = normalizedSql();
        for (String table : Set.of(
                "sales_orders", "sales_shipments", "sales_other_shipments",
                "sales_returns", "sales_quotes", "purchase_requests",
                "purchase_orders", "purchase_receipts", "purchase_returns",
                "stock_documents", "subcontract_inquiries",
                "subcontract_applications", "subcontract_orders",
                "subcontract_material_issues", "subcontract_receipts",
                "subcontract_returns", "subcontract_material_returns",
                "subcontract_wastes", "finance_receipts", "finance_payments",
                "finance_expenses", "finance_other_incomes",
                "finance_bank_transfers", "fixed_assets", "deferred_expenses",
                "production_plans", "production_daily_reports", "rd_tasks",
                "visitor_accounts", "production_execution_segments")) {
            assertTrue(sql.contains(" on " + table + "\n"),
                    () -> "Missing document identifier trigger for " + table);
        }
        assertTrue(sql.contains("is immutable after creation"));
        assertTrue(sql.contains("is immutable after identifier creation"));
    }

    private static Map<String, String> namespacePrefixes(String sql) {
        Map<String, String> result = new LinkedHashMap<>();
        Matcher matcher = NAMESPACE_ROW.matcher(sql);
        while (matcher.find()) {
            result.put(matcher.group(1), matcher.group(3));
        }
        return result;
    }

    private static long namespaceFamilyCount(String sql, String family) {
        Matcher matcher = NAMESPACE_ROW.matcher(sql);
        long count = 0;
        while (matcher.find()) {
            if (family.equals(matcher.group(2))) {
                count++;
            }
        }
        return count;
    }

    private static String sql() throws IOException {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8);
    }

    /**
     * 注册行可由后续迁移追加（如 V299 结算方式 JS）：聚合所有写
     * business_identifier_namespaces 的迁移文本，命名空间契约锁定注册表的最终状态
     * （建表/守卫类断言仍只看 V279 单文件，不受其它迁移文本影响）。
     */
    private static String registrySql() throws IOException {
        try (var files = Files.list(MIGRATION.getParent())) {
            StringBuilder sb = new StringBuilder();
            for (Path file : files
                    .filter(path -> path.getFileName().toString().endsWith(".sql"))
                    .sorted()
                    .toList()) {
                String text = Files.readString(file, StandardCharsets.UTF_8);
                if (text.contains("business_identifier_namespaces")) {
                    sb.append(text).append('\n');
                }
            }
            return sb.toString();
        }
    }

    private static String normalizedSql() throws IOException {
        return sql().replace("\r\n", "\n")
                .replaceAll("[ \\t]+", " ")
                .toLowerCase(java.util.Locale.ROOT);
    }
}
