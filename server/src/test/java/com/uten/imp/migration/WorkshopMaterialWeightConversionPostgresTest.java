package com.uten.imp.migration;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Executes the actual V743/V740 readers and V764 repair against isolated PostgreSQL facts. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WorkshopMaterialWeightConversionPostgresTest {
    private static final PostgreSQLContainer<?> PG = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID KG = UUID.randomUUID(), G = UUID.randomUUID(), ALIAS_G = UUID.randomUUID(),
            UNKNOWN = UUID.randomUUID(), NON_MASS = UUID.randomUUID();
    private static JdbcTemplate db;
    private UUID product;
    private UUID segment;

    @BeforeAll
    static void schema() throws Exception {
        PG.start();
        db = new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        db.execute("""
                CREATE TABLE unit_measurement_profiles(unit_id uuid PRIMARY KEY, measurement_dimension text, mass_unit_code text);
                CREATE TABLE goods(id uuid PRIMARY KEY, issue_method text DEFAULT 'PERIODIC', color_id uuid);
                CREATE TABLE goods_bom_items(id uuid PRIMARY KEY, goods_id uuid, component_goods_id uuid,
                    color_id uuid, qty numeric, is_deleted boolean DEFAULT FALSE);
                CREATE TABLE production_execution_segments(id uuid PRIMARY KEY, product_goods_id uuid);
                CREATE TABLE production_execution_periodic_materials(id uuid PRIMARY KEY, execution_segment_id uuid,
                    material_goods_id uuid, material_color_id uuid, unit_id uuid, origin text,
                    design_qty_snapshot numeric, source_row_id uuid, change_id uuid);
                CREATE TABLE production_execution_material_changes(id uuid PRIMARY KEY, weight_basis text, from_row_id uuid);
                """);
        db.execute(function("V743__warehouse_weight_ledger_and_learning.sql", "fn_weight_unit_kg_factor"));
        db.execute(function("V740__workshop_material_periodic_costing.sql", "fn_workshop_material_edge_weight"));
        db.execute(Files.readString(Path.of("src/main/resources/db/migration/V764__workshop_material_weight_unit_conversion.sql")));
        db.execute(function("V740__workshop_material_periodic_costing.sql", "fn_workshop_material_unit_weight"));
        db.update("INSERT INTO unit_measurement_profiles VALUES (?,'MASS','KG'),(?,'MASS','G'),(?,'MASS','G'),(?,'COUNT','KG')",
                KG, G, ALIAS_G, NON_MASS);
    }

    @BeforeEach
    void reset() {
        db.execute("TRUNCATE goods, goods_bom_items, production_execution_segments, production_execution_periodic_materials, production_execution_material_changes");
        product = UUID.randomUUID();
        segment = UUID.randomUUID();
        db.update("INSERT INTO production_execution_segments VALUES (?,?)", segment, product);
    }

    @AfterAll
    static void stop() { PG.stop(); }

    @Test
    void helperUsesRegisteredDimensionsAndLeavesSameUnitUntouched() {
        decimal("12.5", convert("0.0125", KG, G));
        decimal("0.0125", convert("12.5", G, KG));
        decimal("0.0125", convert("12.5", ALIAS_G, KG));
        decimal("0.0000004", convert("0.0000004", UNKNOWN, UNKNOWN));
        assertNull(convert("1", UNKNOWN, KG));
        assertNull(convert("1", KG, UNKNOWN));
        assertNull(convert("1", NON_MASS, KG));
    }

    @Test
    void replacedCurrentBomWeightIsConvertedToTheNewMaterialUnit() {
        UUID source = row("BOM", KG, "0.008", null, null);
        edge(source, "0.0125");
        UUID changed = change(source, G, "FROM_REPLACED", null);
        edge(changed, "99");
        decimal("12.5", weight(changed));
        assertEquals("REPLACED_ROW_BOM", source(changed));
        decimal("0.0125", weight(source));
    }

    @Test
    void recursiveGramKilogramGramChainConvertsEachBoundaryOnce() {
        UUID original = row("BOM", G, "8.6", null, null);
        UUID kilograms = change(original, KG, "FROM_REPLACED", null);
        UUID grams = change(kilograms, G, "FROM_REPLACED", null);
        UUID back = change(grams, KG, "FROM_REPLACED", null);
        decimal("0.0086", weight(kilograms));
        decimal("8.6", weight(grams));
        decimal("0.0086", weight(back));
        assertEquals("SEGMENT_SNAPSHOT", source(back));
    }

    @Test
    void inheritedFallbackConvertsSourceUnitButOwnSnapshotDoesNot() {
        UUID original = row("BOM", KG, "0.0125", null, null);
        UUID inherited = row("INHERITED", G, null, original, null);
        decimal("12.5", weight(inherited));
        UUID withSnapshot = row("INHERITED", G, "16", original, null);
        decimal("16", weight(withSnapshot));
    }

    @Test
    void unknownCrossUnitWeightStaysUnknownInsteadOfCarryingTheNumber() {
        UUID original = row("BOM", KG, "0.0125", null, null);
        UUID changed = change(original, UNKNOWN, "FROM_REPLACED", null);
        assertNull(weight(changed));
        assertNull(source(changed));
        UUID inherited = row("INHERITED", UNKNOWN, null, original, null);
        assertNull(weight(inherited));
        edge(original, "0.013");
        assertNull(weight(changed), "当前 BOM 分支也不能绕过缺失的单位换算");
    }

    @Test
    void ownBomAndOwnSnapshotAlreadyUseTheTargetUnit() {
        UUID original = row("BOM", KG, "0.0125", null, null);
        UUID own = change(original, G, "OWN_BOM", "15");
        decimal("15", weight(own));
        edge(own, "17.5");
        decimal("17.5", weight(own));
        assertEquals("BOM_AT_CLOSE", source(own));
    }

    private UUID row(String origin, UUID unit, String snapshot, UUID source, UUID change) {
        UUID row = UUID.randomUUID(), material = UUID.randomUUID();
        db.update("INSERT INTO goods(id) VALUES (?)", material);
        db.update("""
                INSERT INTO production_execution_periodic_materials
                    (id,execution_segment_id,material_goods_id,unit_id,origin,design_qty_snapshot,source_row_id,change_id)
                VALUES (?,?,?,?,?,?,?,?)
                """, row, segment, material, unit, origin,
                snapshot == null ? null : new BigDecimal(snapshot), source, change);
        return row;
    }

    private UUID change(UUID original, UUID unit, String basis, String snapshot) {
        UUID change = UUID.randomUUID();
        db.update("INSERT INTO production_execution_material_changes VALUES (?,?,?)", change, basis, original);
        return row("CHANGE", unit, snapshot, null, change);
    }

    private void edge(UUID row, String weight) {
        UUID material = db.queryForObject("SELECT material_goods_id FROM production_execution_periodic_materials WHERE id=?", UUID.class, row);
        db.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES (?,?,?,?)",
                UUID.randomUUID(), product, material, new BigDecimal(weight));
    }

    private BigDecimal weight(UUID row) {
        return db.queryForObject("SELECT unit_weight FROM fn_workshop_material_unit_weight(?)", BigDecimal.class, row);
    }

    private String source(UUID row) {
        return db.queryForObject("SELECT weight_source FROM fn_workshop_material_unit_weight(?)", String.class, row);
    }

    private BigDecimal convert(String qty, UUID from, UUID to) {
        return db.queryForObject("SELECT fn_workshop_material_convert_weight(?,?,?)", BigDecimal.class,
                new BigDecimal(qty), from, to);
    }

    private static void decimal(String expected, BigDecimal actual) {
        assertNotNull(actual);
        assertEquals(0, new BigDecimal(expected).compareTo(actual));
    }

    private static String function(String migration, String name) throws Exception {
        String sql = Files.readString(Path.of("src/main/resources/db/migration", migration));
        int begin = sql.indexOf("CREATE FUNCTION " + name + "(");
        assertTrue(begin >= 0, name);
        return sql.substring(begin, sql.indexOf("$$;", begin) + 3);
    }
}
