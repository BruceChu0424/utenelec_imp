package com.uten.imp.migration;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class CategoryDrivenMasterCodeMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/V258__category_driven_master_codes.sql");
    private static final Path SERVICE = Path.of(
            "src/main/java/com/uten/imp/common/mastercode/CategoryDrivenCodeService.java");

    private static String sql;
    private static String service;

    @BeforeAll
    static void readSources() throws IOException {
        sql = Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .toLowerCase(Locale.ROOT)
                .replaceAll("\\s+", " ");
        service = Files.readString(SERVICE, StandardCharsets.UTF_8)
                .toLowerCase(Locale.ROOT)
                .replaceAll("\\s+", " ");
    }

    @Test
    void categoryPrefixesAreValidatedAndUniqueOnlyInsideTheirDomain() {
        for (String table : new String[]{
                "material_categories", "mould_categories",
                "client_categories", "supplier_categories"}) {
            assertTrue(sql.contains("alter table " + table
                    + " add constraint " + table + "_code_prefix_chk"));
            assertTrue(sql.contains("create unique index " + table
                    + "_active_code_prefix_uq on " + table + "(code_prefix)"));
        }
        assertTrue(sql.contains("^[a-z][a-z0-9]{0,7}$"));
        assertFalse(sql.contains("unique (master_type, code_prefix)"),
                "Prefixes from different master domains must not share one namespace");
    }

    @Test
    void suffixesArePositiveLifetimeUniqueAndSeededFromEveryHistoricalRow() {
        assertTrue(sql.contains("create table category_master_code_sequences"));
        for (String table : new String[]{"goods", "moulds", "clients", "suppliers"}) {
            assertTrue(sql.contains("create unique index " + table
                    + "_code_sequence_uq on " + table + "(code_sequence)"));
            assertTrue(sql.contains("from " + table + " where code_sequence is null"));
            assertTrue(sql.contains("alter table " + table
                    + " alter column code_sequence set not null"));
        }
        assertTrue(service.contains("for update"),
                "The per-master sequence row must serialize every allocation and reconcile");
    }

    @Test
    void subtreeReconcileProtectsCloserOverridesAndUsesTwoPhaseCodes() {
        assertTrue(service.contains("blocked_by_descendant_override"));
        assertTrue(service.contains("child.code_prefix is not null"));
        assertTrue(service.contains("master.code_managed = false"),
                "An explicit category operation must bring legacy/custom rows under the rule");
        assertTrue(service.contains("__mcb_"));
        assertTrue(service.contains("app.master_code_audit_stage"));
        assertTrue(service.contains("\"temporary\""));
        assertTrue(service.contains("\"final\""));
        assertTrue(sql.contains("app.master_code_audit_stage"));
        assertTrue(service.contains(
                "greatest( 6 - length(master.code_sequence::text), 0)"),
                "SQL rendering must pad short suffixes without truncating 7+ digit values");
        assertFalse(service.contains("lpad(master.code_sequence::text, 6"),
                "PostgreSQL lpad truncates suffixes longer than six digits");
    }

    @Test
    void codeUniquenessChecksAreCaseInsensitiveAndRelationshipsStayUuidBased() {
        assertTrue(service.contains("from master_code_reservations reservation"));
        assertTrue(service.contains(
                "reservation.normalized_code = upper(btrim(:code))"));
        assertTrue(service.contains(
                "reservation.normalized_code = upper(btrim(candidate.target_code))"));
        assertTrue(service.contains("from master_code_reservation_members member"));
        assertFalse(service.contains("set category_id ="));
        assertFalse(sql.contains("set category_id ="));
        assertTrue(sql.contains("实体关系始终使用 uuid"));
    }

    @Test
    void prefixAndOwnerChangesShareTheSameSequenceSerializationPoint() {
        int reconcileStart = service.indexOf("public int reconcilesubtree");
        int reconcileLock = service.indexOf("locksequence(type)", reconcileStart);
        int reconcileResolve = service.indexOf("effectiveprefix(type, categoryid)", reconcileStart);
        assertTrue(reconcileStart >= 0 && reconcileLock > reconcileStart);
        assertTrue(reconcileResolve > reconcileLock,
                "Reconcile must lock the master type before resolving final prefix ownership");

        int updateStart = service.indexOf("public categorycodeallocation allocateforupdate");
        int updateLock = service.indexOf("locksequence(type)", updateStart);
        int updateResolve = service.indexOf(
                "effectiveprefixorfallback(type, newcategoryid)", updateStart);
        assertTrue(updateStart >= 0 && updateLock > updateStart);
        assertTrue(updateResolve > updateLock,
                "Move/update must lock before resolving the target owner");
        assertTrue(service.contains(
                "cast(nullif(:resultingowner, '') as uuid) as effective_owner"),
                "Fallback ownership must not bind an untyped null native-query parameter");
    }

    @Test
    void batchHistoryIsAuditedWithoutPersistingGoodsBytea() {
        assertTrue(sql.contains("create table master_code_change_batches"));
        assertTrue(sql.contains("create table master_code_history"));
        assertTrue(sql.contains("trg_audit_master_code_change_batches"));
        assertTrue(sql.contains("trg_audit_master_code_history"));
        for (String bytea : new String[]{
                "ground_graph", "product_graph1", "product_graph2", "product_graph3",
                "product_graph4", "product_graph5", "product_graph6", "budget_graph"}) {
            assertTrue(sql.contains("'" + bytea + "'"));
        }
        assertTrue(sql.indexOf("create or replace function fn_audit_redact_row")
                        < sql.indexOf("update goods g set code_sequence"),
                "Bytea redaction must be installed before the migration updates goods");
        assertTrue(sql.contains("jsonb_build_object"),
                "Batch audit must construct a lightweight row before touching goods bytea");
        assertTrue(sql.contains("'category_master_code_sequences'"),
                "Only the high-churn sequence table may be excluded from the full sweep");
    }
}
