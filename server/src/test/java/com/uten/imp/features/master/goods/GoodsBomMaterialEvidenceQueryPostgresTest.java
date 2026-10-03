package com.uten.imp.features.master.goods;

import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Executes the production query against migrated column shapes in a disposable PostgreSQL database. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsBomMaterialEvidenceQueryPostgresTest {
    static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine");
    Connection db;
    UUID parent, material, unit, color, owner;

    @BeforeAll static void migrate() {
        DATABASE.start();
        Flyway.configure().dataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword())
                .locations("classpath:db/migration").load().migrate();
    }
    @AfterAll static void stop() { DATABASE.stop(); }
    @AfterEach void close() throws Exception { db.close(); }
    @BeforeEach void fixture() throws Exception {
        db = DriverManager.getConnection(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword());
        String schema = "bom_evidence_" + UUID.randomUUID().toString().replace("-", "");
        sql("CREATE SCHEMA " + schema);
        sql("SET search_path TO " + schema + ",public");
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(db, "goods", "units", "colors", "goods_bom_items",
                "goods_periodic_material_choices", "production_execution_segments", "production_plans",
                "production_material_discovery_requests", "production_material_discovery_lines", "production_material_demands");
        unit = UUID.randomUUID(); color = UUID.randomUUID(); owner = UUID.randomUUID();
        sql("INSERT INTO units(id,name) VALUES(?,'千克')", unit);
        sql("INSERT INTO colors(id,name) VALUES(?,'黑色')", color);
        parent = goods("P1"); material = goods("M1");
    }

    @Test void keepsMaterialColorUnitAndSourceIdentityAndDeduplicatesWarehouseLines() throws Exception {
        choice(material, color, false, "MATERIAL");
        request("PENDING", "READY", false, material, color, unit);
        UUID configured = request("CONFIGURED", "COMPLETED", false, material, color, unit);
        line(configured, material, color, unit, false);
        line(configured, material, color, unit, false); // 同一申请分两个仓登记，只计一次。
        UUID secondConfigured = request("CONFIGURED", "IN_PROGRESS", false, material, color, unit);
        line(secondConfigured, material, color, unit, false);
        request("PENDING", "READY", false, material, null, unit);
        UUID otherUnit = UUID.randomUUID();
        sql("INSERT INTO units(id,name) VALUES(?,'克')", otherUnit);
        request("PENDING", "READY", false, material, color, otherUnit);
        sql("UPDATE goods SET color_id=? WHERE id=?", color, material);
        sql("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,is_deleted) VALUES(?,?,?,false)",
                UUID.randomUUID(), parent, material);

        var rows = service().list(parent, owner::equals);

        assertEquals(5, rows.size());
        var periodic = rows.stream().filter(row -> row.source().equals("PERIODIC_CHOICE")).findFirst().orElseThrow();
        assertEquals("CONFIRMED", periodic.status()); assertTrue(periodic.inBom());
        var configuredRow = rows.stream().filter(row -> row.source().equals("DISCOVERY_CONFIGURED")).findFirst().orElseThrow();
        assertEquals(2, configuredRow.sourceCount()); assertTrue(configuredRow.inBom());
        assertEquals(3, rows.stream().filter(row -> row.source().equals("DISCOVERY_REQUEST")).count());
        assertFalse(rows.stream().filter(row -> row.colorId() == null).findFirst().orElseThrow().inBom());
        assertFalse(rows.stream().filter(row -> row.unitId().equals(otherUnit)).findFirst().orElseThrow().inBom());
    }

    @Test void excludesSupersededChoicesCancelledRequestsAndInvalidExecutionEvidence() throws Exception {
        choice(material, color, true, "MATERIAL");
        choice(null, null, false, "NONE");
        request("CANCELLED", "READY", false, material, color, unit);
        request("PENDING", "CANCELLED", false, material, color, unit);
        request("PENDING", "REVERSED", false, material, color, unit);
        request("PENDING", "READY", true, material, color, unit);
        UUID deletedDemand = request("CONFIGURED", "IN_PROGRESS", false, material, color, unit);
        line(deletedDemand, material, color, unit, true);
        UUID valid = request("CONFIGURED", "COMPLETED", false, material, color, unit);
        line(valid, material, color, unit, false);
        UUID otherProduct = goods("OTHER"), unrelated = request("CONFIGURED", "COMPLETED", false, material, color, unit);
        line(unrelated, material, color, unit, false);
        sql("UPDATE production_execution_segments SET product_goods_id=? WHERE id=(SELECT execution_segment_id FROM production_material_discovery_requests WHERE id=?)",
                otherProduct, unrelated);
        sql("UPDATE production_plans SET is_closed=true"); // 有效已登记历史保留，待处理申请不继续显示。
        request("PENDING", "READY", false, material, color, unit);
        sql("UPDATE production_plans SET is_closed=true");

        var rows = service().list(parent, owner::equals);

        assertEquals(1, rows.size());
        assertEquals("DISCOVERY_CONFIGURED", rows.getFirst().source());
        assertEquals(1, rows.getFirst().sourceCount());
    }

    @Test void configuredRequestUsesWarehouseIdentityInsteadOfEarlierRequestedSuggestion() throws Exception {
        UUID actuallyConfigured = goods("M2");
        UUID configured = request("CONFIGURED", "IN_PROGRESS", false, material, color, unit);
        line(configured, actuallyConfigured, null, unit, false);

        var rows = service().list(parent, owner::equals);

        assertEquals(1, rows.size());
        assertEquals(actuallyConfigured, rows.getFirst().componentGoodsId());
        assertEquals("DISCOVERY_CONFIGURED", rows.getFirst().source());
        assertNull(rows.getFirst().colorId());
    }

    private UUID goods(String code) throws Exception {
        UUID id = UUID.randomUUID();
        sql("INSERT INTO goods(id,code,name,unit_id,owner_employee_id,is_deleted,auto_created) VALUES(?,?,?,?,?,false,false)",
                id, code, code, unit, owner);
        return id;
    }
    private void choice(UUID component, UUID chosenColor, boolean superseded, String kind) throws Exception {
        sql("INSERT INTO goods_periodic_material_choices(id,product_goods_id,kind,material_goods_id,material_color_id,chosen_at,superseded_at)"
                + " VALUES(?,?,?,?,?,now(),CASE WHEN ? THEN now() END)", UUID.randomUUID(), parent, kind, component, chosenColor, superseded);
    }
    private UUID request(String state, String segmentState, boolean cancelledPlan, UUID component, UUID requestedColor, UUID requestedUnit) throws Exception {
        UUID plan = UUID.randomUUID(), segment = UUID.randomUUID(), id = UUID.randomUUID();
        sql("INSERT INTO production_plans(id,is_deleted,is_canceled,is_closed) VALUES(?,false,?,false)", plan, cancelledPlan);
        sql("INSERT INTO production_execution_segments(id,plan_id,product_goods_id,status,is_deleted) VALUES(?,?,?,?,false)",
                segment, plan, parent, segmentState);
        sql("INSERT INTO production_material_discovery_requests(id,execution_segment_id,status,created_at,configured_at,requested_materials)"
                + " VALUES(?,?,?,now(),now(),jsonb_build_array(jsonb_build_object('goodsId',CAST(? AS text),'colorId',CAST(? AS text),'unitId',CAST(? AS text))))",
                id, segment, state, component, requestedColor, requestedUnit);
        return id;
    }
    private void line(UUID request, UUID component, UUID lineColor, UUID lineUnit, boolean deleted) throws Exception {
        UUID demand = UUID.randomUUID();
        sql("INSERT INTO production_material_demands(id,is_deleted) VALUES(?,?)", demand, deleted);
        sql("INSERT INTO production_material_discovery_lines(id,request_id,demand_id,goods_id,color_id,unit_id) VALUES(?,?,?,?,?,?)",
                UUID.randomUUID(), request, demand, component, lineColor, lineUnit);
    }
    private GoodsBomMaterialEvidenceQuery service() {
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            String sql = call.getArgument(0);
            Query query = mock(Query.class);
            UUID[] goods = new UUID[1];
            when(query.setParameter(eq("goods"), any())).thenAnswer(binding -> { goods[0] = binding.getArgument(1); return query; });
            when(query.getResultList()).thenAnswer(ignored -> {
                try (var statement = db.prepareStatement(sql.replace(":goods", "?"))) {
                    for (int i = 1; i <= statement.getParameterMetaData().getParameterCount(); i++) statement.setObject(i, goods[0]);
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
    private void sql(String command, Object... arguments) throws Exception {
        try (var statement = db.prepareStatement(command)) {
            for (int i = 0; i < arguments.length; i++) statement.setObject(i + 1, arguments[i]);
            statement.execute();
        }
    }
}
