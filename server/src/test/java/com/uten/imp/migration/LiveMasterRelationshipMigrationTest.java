package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LiveMasterRelationshipMigrationTest {

    @Test
    void v182AddsOnlyAdditiveAuditedLiveUuidRelationships() throws IOException {
        String sql;
        try (var stream = getClass().getResourceAsStream(
                "/db/migration/V182__live_master_relationship_uuid_hardening.sql")) {
            if (stream == null) {
                throw new IOException("V182 migration resource is missing");
            }
            sql = new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }
        String normalized = sql.replaceAll("\\s+", " ");

        for (String column : List.of(
                "unit_id UUID",
                "color_id UUID",
                "mould_id UUID",
                "client_id UUID",
                "default_supplier_id UUID",
                "secondary_supplier_id UUID",
                "maker_name_snapshot TEXT",
                "approver_name_snapshot TEXT")) {
            assertTrue(normalized.contains("ADD COLUMN " + column));
            assertFalse(normalized.contains("ADD COLUMN " + column + " NOT NULL"));
        }

        assertTrue(normalized.contains("u.legacy_id = g.unit_legacy_id"));
        assertTrue(normalized.contains("c.legacy_id = g.color_legacy_id"));
        assertTrue(normalized.contains("m.legacy_id = g.mould_legacy_id"));
        assertTrue(normalized.contains("c.legacy_id = g.client_legacy_id"));
        assertTrue(normalized.contains("s.legacy_id = g.vend_legacy_id"));
        assertTrue(normalized.contains("s.legacy_id = g.vend2_legacy_id"));
        assertTrue(normalized.contains("c.legacy_id = bi.color_legacy_id"));
        assertTrue(normalized.contains("s.legacy_id = bi.vend_legacy_id"));
        assertTrue(normalized.contains("e.legacy_id = d.worker_legacy_id"));
        assertFalse(normalized.contains("e.legacy_id = d.maker_legacy_id"));
        assertFalse(normalized.contains("e.legacy_id = d.approver_legacy_id"));
        assertFalse(normalized.contains("SET maker_id = e.id"));
        assertFalse(normalized.contains("SET approver_id = e.id"));
        assertFalse(sql.contains("STOCK_MAKER_LEGACY_UNMAPPED"));
        assertFalse(sql.contains("STOCK_APPROVER_LEGACY_UNMAPPED"));

        int stockConstraintPosition = normalized.indexOf(
                "ALTER TABLE stock_documents ADD CONSTRAINT fk_stock_documents_supplier");
        int stockBackfillPosition = normalized.indexOf(
                "UPDATE stock_documents d SET worker_id");
        assertTrue(stockConstraintPosition >= 0 && stockConstraintPosition < stockBackfillPosition,
                "stock FK DDL must precede backfill to avoid pending trigger events");

        for (String constraint : List.of(
                "fk_goods_unit_live",
                "fk_goods_color_live",
                "fk_goods_mould_live",
                "fk_goods_client_live",
                "fk_goods_default_supplier_live",
                "fk_goods_secondary_supplier_live",
                "fk_goods_bom_color_live",
                "fk_goods_bom_default_supplier_live",
                "fk_mould_department_live",
                "fk_mould_keeper_live",
                "fk_stock_documents_supplier",
                "fk_stock_documents_client",
                "fk_stock_documents_worker",
                "fk_stock_documents_maker",
                "fk_stock_documents_approver")) {
            assertTrue(
                    normalized.matches("(?s).*ADD CONSTRAINT " + constraint
                            + " .*? NOT VALID[,;].*"),
                    constraint + " must remain NOT VALID in V182");
        }

        assertTrue(normalized.contains(
                "ADD CONSTRAINT goods_bom_qty_positive_chk CHECK (qty > 0) NOT VALID"));
        assertTrue(normalized.contains(
                "ADD CONSTRAINT goods_bom_no_self_component_chk "
                        + "CHECK (goods_id <> component_goods_id) NOT VALID"));

        assertTrue(sql.contains("legacy_migration_runs"));
        assertTrue(sql.contains("legacy_migration_rejects"));
        assertTrue(sql.contains("legacy_migration_reconciliation_items"));
        assertTrue(normalized.contains("HAVING COUNT(*) > 1"));
        assertTrue(normalized.contains("UPDATE moulds m SET department_id = NULL"));
        assertTrue(normalized.contains("UPDATE moulds m SET keeper_id = NULL"));
        assertTrue(normalized.contains(
                "WHEN v_issue_count > 0 OR v_failed_metric_count > 0 THEN 'FAILED'"));
        assertTrue(normalized.contains("WHEN v_source_ref_count = 0 THEN 'NOT_RUN'"));
        assertTrue(normalized.contains("ELSE 'PASSED'"));
        assertTrue(normalized.contains("+ (SELECT COUNT(*) FROM goods_bom_items)"));
        assertTrue(sql.contains("'postImportReconciliationRequired', true"));
        assertTrue(sql.contains("'productionAcceptance', false"));

        assertFalse(normalized.contains("SELECT DISTINCT ON"));
        assertFalse(normalized.contains("SET department_id = x.id"));
        assertFalse(normalized.contains("SET keeper_id = x.id"));
        assertFalse(normalized.contains("DROP COLUMN"));
        assertFalse(normalized.contains("SET NOT NULL"));
        assertFalse(normalized.contains("VALIDATE CONSTRAINT"));
    }

    @Test
    void stockLegacyPersonnelKeepsWorkerAndOperatorNamespacesSeparate() throws IOException {
        String importSql = sourceFile("legacy_migration/migrate_stock_docs.sql");
        String importNormalized = importSql.replaceAll("\\s+", " ");
        assertTrue(importNormalized.contains(
                "CREATE TEMP TABLE operator_ref_stage (legacy_id int, name text)"));
        assertTrue(importSql.contains(
                "\\copy operator_ref_stage FROM '/tmp/legacy_operators_ref.csv'"));
        assertTrue(importNormalized.contains(
                "worker_id, worker_legacy_id, maker_legacy_id, approver_legacy_id, "
                        + "maker_name_snapshot, approver_name_snapshot"));
        assertTrue(importNormalized.contains(
                "e.legacy_id = NULLIF(s.worker_legacy,0)"));
        assertTrue(importNormalized.contains(
                "op.legacy_id = NULLIF(s.maker_legacy,0)"));
        assertTrue(importNormalized.contains(
                "op.legacy_id = NULLIF(s.approver_legacy,0)"));

        String report = sourceFile(
                "src/main/java/com/uten/imp/features/stock/report/StockReportService.java")
                .replaceAll("\\s+", " ");
        assertTrue(report.contains(
                "LEFT JOIN employees em_wk ON em_wk.id = o.worker_id "
                        + "OR (o.worker_id IS NULL AND em_wk.legacy_id = o.worker_legacy_id)"));
        assertTrue(report.contains("LEFT JOIN employees em_mk ON em_mk.id = o.maker_id"));
        assertTrue(report.contains("LEFT JOIN employees em_ap ON em_ap.id = o.approver_id"));
        assertFalse(report.contains("em_mk.legacy_id"));
        assertFalse(report.contains("em_ap.legacy_id"));
        assertTrue(report.contains("o.maker_name_snapshot"));
        assertTrue(report.contains("o.approver_name_snapshot"));

        String entity = sourceFile(
                "src/main/java/com/uten/imp/features/stock/StockDocument.java");
        assertTrue(entity.contains("@Column(name = \"maker_name_snapshot\")"));
        assertTrue(entity.contains("@Column(name = \"approver_name_snapshot\")"));

        String migrateSh = sourceFile("legacy_migration/migrate.sh");
        String stockBlock = migrateSh.substring(
                migrateSh.indexOf("migrate_stock_docs ()"),
                migrateSh.indexOf("migrate_sales ()"));
        assertTrue(stockBlock.contains("legacy_workers legacy_operators_ref"));
        assertTrue(migrateSh.contains("grep -F \" *$1\" \"$checksum_manifest\""));
        assertTrue(migrateSh.contains("sha256sum -c -"));

        String exporter = sourceFile("legacy_migration/export_legacy.ps1");
        String warehouseBlock = exporter.substring(
                exporter.indexOf("'WarehouseDocs' {"),
                exporter.indexOf("'SalesQuote' {"));
        assertTrue(warehouseBlock.contains(
                "'legacy_operators_ref.csv'"));
    }

    private static String sourceFile(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct)
                ? direct
                : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path, StandardCharsets.UTF_8);
    }
}
