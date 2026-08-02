package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Static guard for the Flyway audit-trigger contract.
 *
 * <p>V169 is the immutable original full-table sweep, V184 refreshes that
 * contract after later business tables were introduced, V185 hardens
 * soft-delete semantics plus row minimization, V190 covers the V188/V189
 * business tables, V193 covers V191/V192 planning tables, and V195 covers the V194 MAKE receipt-allocation ledger.
 * This test deliberately
 * does not pretend to execute PostgreSQL trigger DDL. Instead it verifies the
 * part that can be proven without Docker: critical tables existed before the
 * latest trusted sweep, and no later table can silently appear outside the
 * explicit technical-table allowlist. Runtime {@code pg_trigger} inspection
 * remains a deployment acceptance check.
 */
class AuditTriggerCoverageMigrationContractTest {

    private static final Path MIGRATION_ROOT = Path.of("src/main/resources/db/migration");
    private static final int LATEST_FULL_AUDIT_SWEEP_VERSION = 195;
    private static final Path LATEST_FULL_AUDIT_SWEEP =
            MIGRATION_ROOT.resolve("V195__refresh_audit_trigger_coverage.sql");
    private static final Path LATEST_AUDIT_HARDENING =
            MIGRATION_ROOT.resolve("V185__audit_soft_delete_and_redaction_hardening.sql");
    private static final Pattern MIGRATION_FILE =
            Pattern.compile("^V(\\d+)__.+\\.sql$");
    private static final Pattern CREATE_TABLE = Pattern.compile(
            "(?i)\\bCREATE\\s+TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?"
                    + "(?:(?:\\x22)?public(?:\\x22)?\\s*\\.\\s*)?"
                    + "(?:\\x22)?([a-z_][a-z0-9_]*)(?:\\x22)?");

    private static final Set<String> REQUIRED_BUSINESS_TABLES = Set.of(
            // Core master data and all four category trees.
            "goods", "material_categories", "mould_categories",
            "client_categories", "supplier_categories", "clients", "suppliers",
            // Inventory facts.
            "stock_balances", "stock_movements", "stock_documents", "stock_document_items",
            // Purchase and sales order heads/lines.
            "purchase_orders", "purchase_order_items", "sales_orders", "sales_order_items",
            // Accounts, authorization, data scopes and organization.
            "users", "roles", "permissions", "user_roles", "role_permissions",
            "user_permission_overrides", "department_permissions", "user_data_scopes",
            "departments", "positions", "employees",
            // Professional asset and deferral subledger introduced immediately before V184.
            "finance_asset_categories", "finance_asset_books",
            "finance_deferral_schedule_versions", "finance_deferral_schedule_lines",
            "finance_asset_approval_steps", "finance_asset_events",
            "finance_asset_accounting_periods", "finance_asset_posting_runs",
            "finance_asset_posting_lines",
            // Warehouse shipment and sales-return quality ledgers added before V190.
            "sales_shipment_warehouse_events", "sales_return_quality_items",
            "sales_return_quality_events",
            // Pre-approval planning, workshop defaults and MAKE receipt provenance.
            "production_planning_drafts", "production_goods_workshop_preferences",
            "production_material_make_receipt_allocations");

    /** Tables intentionally excluded from row-image auditing, with reviewable reasons. */
    private static final Map<String, String> TECHNICAL_TABLE_ALLOWLIST = Map.ofEntries(
            Map.entry("audit_log", "audit sink; auditing itself would recurse"),
            Map.entry("audit_log_archive", "immutable cold archive of the audit sink"),
            Map.entry("flyway_schema_history", "Flyway-owned migration metadata"),
            Map.entry("spatial_ref_sys", "PostGIS extension metadata"),
            Map.entry("authorization_state", "high-churn authorization epoch"),
            Map.entry("doc_number_sequences", "atomic document-number counter"),
            Map.entry("master_code_sequences", "atomic master-code counter"),
            Map.entry("report_materialized_view_refresh_state", "materialized-view refresh metadata"),
            Map.entry("password_history", "credential-derived security data"),
            Map.entry("refresh_tokens", "staff credential material"),
            Map.entry("visitor_refresh_tokens", "visitor credential material"),
            Map.entry("visitor_sms_codes", "one-time credential material"),
            Map.entry("legacy_migration_checkpoints", "legacy migration control metadata"),
            Map.entry("legacy_migration_reconciliation_items", "legacy reconciliation metadata"),
            Map.entry("legacy_migration_rejects", "legacy migration rejection metadata"),
            Map.entry("legacy_migration_run_files", "legacy migration file metadata"),
            Map.entry("legacy_migration_runs", "legacy migration run metadata"));

    @Test
    void latestTrustedSweepValidatesTheFullTriggerContract() throws IOException {
        assertTrue(Files.isRegularFile(LATEST_FULL_AUDIT_SWEEP),
                "The declared latest audit sweep migration must exist");

        String sql = stripSqlComments(Files.readString(
                LATEST_FULL_AUDIT_SWEEP, StandardCharsets.UTF_8))
                .replaceAll("\\s+", " ")
                .toLowerCase(java.util.Locale.ROOT);
        assertTrue(sql.contains("tgname like 'trg_audit%'"),
                "The sweep must identify existing audit triggers by the shared prefix");
        assertTrue(sql.contains("tgenabled in ('o', 'a')"),
                "Disabled audit triggers must not satisfy coverage");
        assertTrue(sql.contains("tgtype::integer & 1")
                        && sql.contains("tgtype::integer & 2")
                        && sql.contains("tgtype::integer & 4")
                        && sql.contains("tgtype::integer & 8")
                        && sql.contains("tgtype::integer & 16"),
                "Coverage must require AFTER ROW INSERT/UPDATE/DELETE semantics");
        assertTrue(sql.contains("join pg_proc")
                        && sql.contains("fn_audit_redacted"),
                "Coverage must validate the called redacting audit function");
        assertTrue(sql.contains("count(*) filter")
                        && sql.contains("prefixed_trigger_count = 1")
                        && sql.contains("valid_trigger_count = 1"),
                "Each business table must have exactly one valid audit trigger");
        assertTrue(sql.contains("raise exception"),
                "A malformed prefixed trigger must fail the migration closed");
        assertTrue(sql.contains("execute function fn_audit()"),
                "The sweep must attach the shared redacting audit function");
        assertTrue(sql.contains("'master_code_sequences'"),
                "High-churn master-code counters must remain explicitly excluded");
    }

    @Test
    void latestHardeningPreservesSoftDeleteMeaningAndRedaction() throws IOException {
        assertTrue(Files.isRegularFile(LATEST_AUDIT_HARDENING),
                "The post-sweep audit hardening migration must exist");
        String sql = stripSqlComments(Files.readString(
                LATEST_AUDIT_HARDENING, StandardCharsets.UTF_8))
                .replaceAll("\\s+", " ")
                .toLowerCase(java.util.Locale.ROOT);

        assertTrue(sql.contains("create or replace function fn_audit_redact_row"));
        assertTrue(sql.contains("create or replace function fn_audit_redacted()"));
        for (String field : List.of(
                "preview_token_hash", "last_rejection_reason", "close_reason",
                "reopen_reason", "reversal_reason", "payload",
                "exception_snapshot", "calculation_snapshot",
                "required_document_codes", "required_document_codes_snapshot",
                "source_ref", "source_line_ref")) {
            assertTrue(sql.contains("'" + field + "'"),
                    () -> "Sensitive/free-text field must be redacted: " + field);
        }
        assertTrue(sql.contains("v_action := 'delete'"),
                "Future is_deleted/deleted_at transitions must be stored as delete");
        assertEquals(2, sql.split("v_action := 'delete'", -1).length - 1,
                "Both generic and high-sensitivity trigger functions must store soft deletes");
        assertTrue(sql.contains("v_identity ->> 'period'"),
                "Accounting-period rows need a stable target id");
        assertTrue(sql.contains("app.audit_device_context"),
                "Replacing fn_audit must retain the V172 device context");
        assertTrue(sql.contains("client_event_id"),
                "Database audit rows must retain local request correlation");
        assertTrue(sql.contains("device_profile_hash"),
                "Database audit rows must retain the redacted device fingerprint");
    }

    @Test
    void createTableParserHandlesQuotedAndUnquotedIdentifiers() {
        Matcher plain = CREATE_TABLE.matcher("CREATE TABLE public.goods (id UUID)");
        assertTrue(plain.find());
        assertEquals("goods", plain.group(1));

        String quote = Character.toString(34);
        Matcher quoted = CREATE_TABLE.matcher("CREATE TABLE IF NOT EXISTS "
                + quote + "public" + quote + "." + quote + "Goods_Audit" + quote
                + " (id UUID)");
        assertTrue(quoted.find());
        assertEquals("Goods_Audit", quoted.group(1));
    }

    @Test
    void criticalBusinessTablesExistBeforeTheTrustedFullAuditSweep() throws IOException {
        Map<String, Integer> createdAt = createdTableVersions();

        List<String> missing = REQUIRED_BUSINESS_TABLES.stream()
                .filter(table -> !createdAt.containsKey(table))
                .sorted()
                .toList();
        assertTrue(missing.isEmpty(),
                () -> "Required audited tables are absent from Flyway DDL: " + missing);

        List<String> tooLate = REQUIRED_BUSINESS_TABLES.stream()
                .filter(table -> createdAt.get(table) > LATEST_FULL_AUDIT_SWEEP_VERSION)
                .sorted()
                .map(table -> table + "@V" + createdAt.get(table))
                .toList();
        assertTrue(tooLate.isEmpty(),
                () -> "Business tables created after V" + LATEST_FULL_AUDIT_SWEEP_VERSION
                        + " are not covered by its full audit sweep. Add a later sweep and "
                        + "advance LATEST_FULL_AUDIT_SWEEP_VERSION: " + tooLate);
    }

    @Test
    void tablesCreatedAfterTheTrustedSweepMustBeExplicitlyTechnical() throws IOException {
        Map<String, Integer> createdAt = createdTableVersions();
        List<String> unreviewed = createdAt.entrySet().stream()
                .filter(entry -> entry.getValue() > LATEST_FULL_AUDIT_SWEEP_VERSION)
                .filter(entry -> !TECHNICAL_TABLE_ALLOWLIST.containsKey(entry.getKey()))
                .sorted(Map.Entry.comparingByKey())
                .map(entry -> entry.getKey() + "@V" + entry.getValue())
                .toList();

        assertTrue(unreviewed.isEmpty(),
                () -> "Tables created after the latest full audit sweep require a later sweep. "
                        + "Only genuinely technical tables may enter TECHNICAL_TABLE_ALLOWLIST: "
                        + unreviewed);
    }

    @Test
    void technicalAllowlistCannotHideRequiredBusinessTables() {
        Set<String> overlap = REQUIRED_BUSINESS_TABLES.stream()
                .filter(TECHNICAL_TABLE_ALLOWLIST::containsKey)
                .collect(java.util.stream.Collectors.toSet());
        assertEquals(Set.of(), overlap,
                "A required business table must never be hidden by the technical allowlist");
        assertFalse(TECHNICAL_TABLE_ALLOWLIST.values().stream().anyMatch(String::isBlank),
                "Every audit exclusion needs a reviewable reason");
    }

    private Map<String, Integer> createdTableVersions() throws IOException {
        List<MigrationSource> migrations = new ArrayList<>();
        try (var files = Files.list(MIGRATION_ROOT)) {
            for (Path path : files.filter(Files::isRegularFile).toList()) {
                Matcher matcher = MIGRATION_FILE.matcher(path.getFileName().toString());
                if (!matcher.matches()) {
                    continue;
                }
                migrations.add(new MigrationSource(
                        Integer.parseInt(matcher.group(1)),
                        path,
                        Files.readString(path, StandardCharsets.UTF_8)));
            }
        }
        migrations.sort(Comparator.comparingInt(MigrationSource::version));

        Map<String, Integer> createdAt = new LinkedHashMap<>();
        for (MigrationSource migration : migrations) {
            Matcher table = CREATE_TABLE.matcher(stripSqlComments(migration.sql()));
            while (table.find()) {
                createdAt.putIfAbsent(table.group(1).toLowerCase(), migration.version());
            }
        }
        return createdAt;
    }

    /** Removes SQL comments so documentation examples cannot look like DDL. */
    private String stripSqlComments(String sql) {
        StringBuilder result = new StringBuilder(sql.length());
        boolean lineComment = false;
        boolean blockComment = false;
        boolean quoted = false;
        for (int index = 0; index < sql.length(); index++) {
            char current = sql.charAt(index);
            char next = index + 1 < sql.length() ? sql.charAt(index + 1) : '\0';
            if (lineComment) {
                if (current == '\n') {
                    lineComment = false;
                    result.append(current);
                }
                continue;
            }
            if (blockComment) {
                if (current == '*' && next == '/') {
                    blockComment = false;
                    index++;
                }
                continue;
            }
            if (!quoted && current == '-' && next == '-') {
                lineComment = true;
                index++;
                continue;
            }
            if (!quoted && current == '/' && next == '*') {
                blockComment = true;
                index++;
                continue;
            }
            if (current == '\'') {
                if (quoted && next == '\'') {
                    result.append(current).append(next);
                    index++;
                    continue;
                }
                quoted = !quoted;
            }
            result.append(current);
        }
        return result.toString();
    }

    private record MigrationSource(int version, Path path, String sql) {
    }
}
