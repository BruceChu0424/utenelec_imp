package com.uten.imp.features.master.goods;

import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** The migrated table and production evidence reader preserve unknown usage as unknown. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsMaterialIdentityEvidencePostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection db;
    private UUID product, material, unit, pieceUnit, color, run;

    @BeforeAll static void migrate() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("material_identity");
    }
    @AfterAll static void stop() throws Exception { if (database != null) database.close(); }
    @BeforeEach void fixture() throws Exception {
        db = database.openConnection();
        db.setAutoCommit(false);
        unit = UUID.randomUUID(); color = UUID.randomUUID(); run = UUID.randomUUID();
        sql("INSERT INTO units(id,code,name,status) VALUES(?,?,'kg','使用')", unit, "IDENTITY-U-" + unit);
        sql("INSERT INTO colors(id,code,name,status) VALUES(?,?,'原色','使用')", color, "IDENTITY-C-" + color);
        product = goods("1M0004"); material = goods("PC面板料 E-15");
        pieceUnit = UUID.randomUUID();
        sql("INSERT INTO units(id,code,name,status) VALUES(?,?,'个','使用')", pieceUnit, "IDENTITY-P-U-" + pieceUnit);
        sql("UPDATE goods SET unit_id=? WHERE id=?", pieceUnit, product);
        sql("INSERT INTO legacy_migration_runs(run_id,target,status) VALUES(?,'material-identity-test','SUCCESS')", run);
    }
    @AfterEach void close() throws Exception { if (db != null) { db.rollback(); db.close(); } }

    @Test void unknownQuantityIsReadableButCreatesNoRecipeDemandCostOrIssuePolicy() throws Exception {
        UUID identity = identity(product, material, null);

        var rows = service().list(product, ignored -> true);

        assertEquals(1, rows.size());
        var row = rows.getFirst();
        assertEquals("MATERIAL_IDENTITY", row.source());
        assertEquals("PENDING_QUANTITY", row.status());
        assertEquals(material, row.componentGoodsId());
        assertEquals(unit, row.unitId()); assertFalse(row.inBom());
        assertEquals(1, row.sourceCount());
        assertEquals("ORDER", text("SELECT issue_method FROM goods WHERE id=?", material));
        assertNull(text("SELECT periodic_cost_basis FROM goods WHERE id=?", material));
        assertEquals("ORDER", text("SELECT issue_method FROM goods WHERE id=?", product));
        assertEquals(pieceUnit.toString(), text("SELECT unit_id::text FROM goods WHERE id=?", product));
        assertFalse(bool("SELECT fn_goods_has_bom(?)", product));
        assertEquals(0, number("SELECT count(*) FROM goods_bom_items WHERE goods_id=?", product));
        assertEquals(0, number("SELECT count(*) FROM production_material_demands WHERE goods_id=?", material));
        assertEquals(0, number("SELECT count(*) FROM stock_movements WHERE goods_id=?", material));
        assertEquals(0, new java.math.BigDecimal("17").compareTo(new java.math.BigDecimal(text("SELECT source_e::text FROM goods WHERE id=?", product))));
        assertEquals(0, number("SELECT count(*) FROM information_schema.columns WHERE table_name='goods_material_identity_evidence' AND column_name IN ('qty','price','unit_rate','required_qty','unit_weight','amount')"));
        assertEquals(1, number("SELECT count(*) FROM audit_log WHERE target_type='goods_material_identity_evidence' AND target_id=?", identity.toString()));
    }

    @Test void sameIdentityCannotDuplicateOrPointToItselfAndImportProofIsRequired() throws Exception {
        identity(product, material, null);
        rejects("23505", "INSERT INTO goods_material_identity_evidence(product_goods_id,material_goods_id,source_kind,provenance,import_run_id) VALUES(?,?,'LEGACY_MATERIAL_TEXT','{\"source\":\"repeat\"}',?)", product, material, run);
        rejects("23514", "INSERT INTO goods_material_identity_evidence(product_goods_id,material_goods_id,source_kind,provenance,import_run_id) VALUES(?,?,'LEGACY_MATERIAL_TEXT','{\"source\":\"self\"}',?)", product, product, run);
        rejects("23514", "INSERT INTO goods_material_identity_evidence(product_goods_id,material_goods_id,source_kind,provenance) VALUES(?,?,'LEGACY_MATERIAL_TEXT','{\"source\":\"no-run\"}')", material, product);
        rejects("23514", "INSERT INTO goods_material_identity_evidence(product_goods_id,material_goods_id,source_kind,provenance,import_run_id) VALUES(?,?,'LEGACY_MATERIAL_TEXT','{}',?)", material, product, run);
        rejects("23503", "INSERT INTO goods_material_identity_evidence(product_goods_id,material_goods_id,source_kind,provenance,import_run_id) VALUES(?,?,'LEGACY_MATERIAL_TEXT','{\"source\":\"missing-run\"}',?)", material, product, UUID.randomUUID());
    }

    @Test void missingDeletedOrPlaceholderEndpointsCannotBecomeActiveMaterialIdentity() throws Exception {
        rejects("23503", "INSERT INTO goods_material_identity_evidence(product_goods_id,material_goods_id,source_kind,provenance,import_run_id) VALUES(?,?,'LEGACY_MATERIAL_TEXT','{\"source\":\"missing-material\"}',?)", product, UUID.randomUUID(), run);
        UUID placeholder = goods("historical anchor");
        sql("UPDATE goods SET auto_created=true WHERE id=?", placeholder);
        rejects("23514", "INSERT INTO goods_material_identity_evidence(product_goods_id,material_goods_id,source_kind,provenance,import_run_id) VALUES(?,?,'LEGACY_MATERIAL_TEXT','{\"source\":\"placeholder\"}',?)", product, placeholder, run);
        UUID deleted = goods("deleted material");
        sql("UPDATE goods SET is_deleted=true,deleted_at=now() WHERE id=?", deleted);
        rejects("23514", "INSERT INTO goods_material_identity_evidence(product_goods_id,material_goods_id,source_kind,provenance,import_run_id) VALUES(?,?,'LEGACY_MATERIAL_TEXT','{\"source\":\"deleted\"}',?)", product, deleted, run);
        rejects("23514", "INSERT INTO goods_material_identity_evidence(product_goods_id,material_goods_id,source_kind,provenance,import_run_id) VALUES(?,?,'LEGACY_MATERIAL_TEXT','{\"source\":\"placeholder-parent\"}',?)", placeholder, material, run);
    }

    @Test void aDisabledParentKeepsItsOwnPendingMaterialIdentityWithoutRestoringAnyRecipe() throws Exception {
        sql("UPDATE goods SET status='禁用' WHERE id=?", product);
        identity(product, material, null);
        assertEquals(1, service().list(product, ignored -> true).size());
        assertEquals("禁用", text("SELECT status FROM goods WHERE id=?", product));
        assertFalse(bool("SELECT fn_goods_has_bom(?)", product));
    }

    @Test void multipleUnknownMaterialsRemainOutsideMrpAndDisabledMaterialsCannotEnterOrRemainVisible() throws Exception {
        UUID otherMaterial = goods("另一已确认注塑原料");
        identity(product, material, null);
        UUID otherEvidence = identity(product, otherMaterial, null);
        var rows = service().list(product, ignored -> true);
        assertEquals(2, rows.size());
        assertTrue(rows.stream().allMatch(row -> row.status().equals("PENDING_QUANTITY") && !row.inBom()));
        assertFalse(bool("SELECT fn_goods_has_bom(?)", product));
        assertEquals(0, number("SELECT count(*) FROM production_material_demands WHERE goods_id IN (?,?)", material, otherMaterial));
        sql("UPDATE goods SET status='禁用' WHERE id=?", otherMaterial);
        assertEquals(1, service().list(product, ignored -> true).size());
        assertEquals(1, number("SELECT count(*) FROM goods_material_identity_evidence WHERE id=?", otherEvidence));
        UUID otherProduct = goods("另一产品");
        rejects("23514", "INSERT INTO goods_material_identity_evidence(product_goods_id,material_goods_id,source_kind,provenance,import_run_id) VALUES(?,?,'LEGACY_MATERIAL_TEXT','{\"source\":\"disabled\"}',?)", otherProduct, otherMaterial, run);
    }

    @Test void onlyTheExactDirectBomMaterialAndColorLinkToAnEstablishedRecipe() throws Exception {
        identity(product, material, color);
        UUID otherColor = UUID.randomUUID();
        sql("INSERT INTO colors(id,code,name,status) VALUES(?,?,'另一颜色','使用')", otherColor, "IDENTITY-C-" + otherColor);
        identity(product, material, otherColor);
        UUID differentIdentity = goods("PC面板料 E-15"); // a name does not establish identity equivalence
        sql("INSERT INTO goods_bom_items(goods_id,component_goods_id,color_id,qty) VALUES(?,?,?,2)", product, differentIdentity, color);
        assertTrue(service().list(product, ignored -> true).stream().noneMatch(GoodsBomMaterialEvidenceQuery.Evidence::inBom));

        sql("INSERT INTO goods_bom_items(goods_id,component_goods_id,color_id,qty) VALUES(?,?,?,0.015)", product, material, color);

        var rows = service().list(product, ignored -> true);
        assertEquals(2, rows.size());
        assertTrue(rows.stream().filter(row -> color.equals(row.colorId())).findFirst().orElseThrow().inBom());
        assertFalse(rows.stream().filter(row -> otherColor.equals(row.colorId())).findFirst().orElseThrow().inBom());
        assertEquals(1, number("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted", product, material));
    }

    @Test void softRetirementAndVisibilityHideIdentityEvidenceWithoutMakingItUsage() throws Exception {
        UUID identity = identity(product, material, null);
        assertTrue(service().list(product, ignored -> false).isEmpty());
        sql("UPDATE goods_material_identity_evidence SET is_deleted=true,deleted_at=now() WHERE id=?", identity);
        assertTrue(service().list(product, ignored -> true).isEmpty());
        assertEquals(1, number("SELECT count(*) FROM goods_material_identity_evidence WHERE id=?", identity));
        identity(product, material, null); // an explicitly retired identity does not prevent a later reviewed record
        assertEquals(1, service().list(product, ignored -> true).size());
        assertFalse(bool("SELECT fn_goods_has_bom(?)", product));
    }

    @Test void relationshipProvenanceAndImportRunRemainIndependentOfRemovedReset() throws Exception {
        UUID identity = identity(product, material, null);
        assertEquals(0, number("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='business_data_reset'"));
        assertEquals(1, number("SELECT count(*) FROM goods_material_identity_evidence WHERE id=? AND import_run_id=? AND provenance->>'rule'='EXACT_E15'", identity, run));
        assertEquals(1, number("SELECT count(*) FROM legacy_migration_runs WHERE run_id=?", run));
        assertFalse(bool("SELECT fn_goods_has_bom(?)", product));
    }

    private UUID goods(String name) throws SQLException {
        UUID id = UUID.randomUUID();
        sql("INSERT INTO goods(id,code,name,unit_id,status,source_type,source_e,code_sequence) VALUES(?,?,?,?,'使用','自制',17,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))", id, "IDENTITY-G-" + id, name, unit);
        return id;
    }
    private UUID identity(UUID parent, UUID component, UUID shade) throws SQLException {
        UUID id = UUID.randomUUID();
        sql("INSERT INTO goods_material_identity_evidence(id,product_goods_id,material_goods_id,material_color_id,source_kind,provenance,import_run_id) VALUES(?,?,?,?,'LEGACY_MATERIAL_TEXT','{\"rule\":\"EXACT_E15\",\"quantity\":\"unknown\"}',?)", id, parent, component, shade, run);
        return id;
    }
    private void rejects(String state, String command, Object... args) throws SQLException {
        var savepoint = db.setSavepoint();
        SQLException failure = assertThrows(SQLException.class, () -> sql(command, args));
        assertEquals(state, failure.getSQLState());
        db.rollback(savepoint);
    }
    private void sql(String command, Object... args) throws SQLException {
        try (var statement = db.prepareStatement(command)) {
            for (int i = 0; i < args.length; i++) statement.setObject(i + 1, args[i]);
            statement.execute();
        }
    }
    private String text(String command, Object... args) throws SQLException {
        try (var statement = db.prepareStatement(command)) {
            for (int i = 0; i < args.length; i++) statement.setObject(i + 1, args[i]);
            try (var result = statement.executeQuery()) { assertTrue(result.next()); return result.getString(1); }
        }
    }
    private long number(String command, Object... args) throws SQLException { return Long.parseLong(text(command, args)); }
    private boolean bool(String command, Object... args) throws SQLException {
        String value = text(command, args);
        return "t".equals(value) || "true".equalsIgnoreCase(value);
    }
    private GoodsBomMaterialEvidenceQuery service() {
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            String command = call.getArgument(0);
            Query query = mock(Query.class);
            UUID[] target = new UUID[1];
            when(query.setParameter(eq("goods"), any())).thenAnswer(binding -> { target[0] = binding.getArgument(1); return query; });
            when(query.getResultList()).thenAnswer(ignored -> {
                try (var statement = db.prepareStatement(command.replace(":goods", "?"))) {
                    for (int i = 1; i <= statement.getParameterMetaData().getParameterCount(); i++) statement.setObject(i, target[0]);
                    try (var result = statement.executeQuery()) {
                        List<Object[]> rows = new ArrayList<>();
                        while (result.next()) {
                            Object[] row = new Object[result.getMetaData().getColumnCount()];
                            for (int i = 0; i < row.length; i++) row[i] = result.getObject(i + 1);
                            rows.add(row);
                        }
                        return rows;
                    }
                }
            });
            return query;
        });
        return new GoodsBomMaterialEvidenceQuery(em);
    }
}
