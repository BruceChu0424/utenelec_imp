package com.uten.imp.migration;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Actual V765 trigger: an unconfigured request is intent, not permission to post stock. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WorkshopMaterialRequestBeforeSetupPostgresTest {
    private static final PostgreSQLContainer<?> PG = new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private UUID unit, goods;

    @BeforeAll
    static void schema() throws Exception {
        PG.start();
        db = new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        db.execute("""
                CREATE TABLE units(id uuid PRIMARY KEY,status text,is_deleted boolean DEFAULT FALSE);
                CREATE TABLE unit_measurement_profiles(unit_id uuid PRIMARY KEY,measurement_dimension text);
                CREATE TABLE goods(id uuid PRIMARY KEY,unit_id uuid,issue_method text,status text,is_deleted boolean DEFAULT FALSE);
                CREATE TABLE workshop_material_requisitions(id uuid PRIMARY KEY,kind text,origin text,status text);
                CREATE TABLE workshop_material_requisition_lines(id uuid PRIMARY KEY,requisition_id uuid,
                    goods_id uuid,unit_id uuid,requested_qty numeric,fulfilled_qty numeric DEFAULT 0);
                """);
        db.execute(Files.readString(Path.of("src/main/resources/db/migration/V765__workshop_material_request_before_setup.sql")));
        db.execute("CREATE TRIGGER guard BEFORE INSERT OR UPDATE OR DELETE ON workshop_material_requisition_lines FOR EACH ROW EXECUTE FUNCTION fn_guard_wm_requisition_line()");
    }

    @BeforeEach
    void facts() {
        db.execute("TRUNCATE units, unit_measurement_profiles, goods, workshop_material_requisitions, workshop_material_requisition_lines");
        unit = UUID.randomUUID(); goods = UUID.randomUUID();
        db.update("INSERT INTO units(id,status) VALUES (?,'使用')", unit);
        db.update("INSERT INTO unit_measurement_profiles VALUES (?,'MASS')", unit);
        db.update("INSERT INTO goods(id,unit_id,issue_method,status) VALUES (?,?,'ORDER','使用')", goods, unit);
    }

    @AfterAll
    static void stop() { PG.stop(); }

    @Test
    void onlyPendingWorkshopIssueCanRequestAnOrderMaterial() {
        UUID line = insert("ISSUE", "WORKSHOP_REQUEST", "PENDING", unit);
        assertEquals("ORDER", db.queryForObject("SELECT issue_method FROM goods WHERE id=?", String.class, goods));
        assertThrows(DataAccessException.class, () -> db.update(
                "UPDATE workshop_material_requisition_lines SET fulfilled_qty=1 WHERE id=?", line));
        UUID positiveRequest = UUID.randomUUID();
        db.update("INSERT INTO workshop_material_requisitions VALUES (?,'ISSUE','WORKSHOP_REQUEST','PENDING')", positiveRequest);
        assertThrows(DataAccessException.class, () -> db.update("""
                INSERT INTO workshop_material_requisition_lines(id,requisition_id,goods_id,unit_id,requested_qty,fulfilled_qty)
                VALUES (?,?,?,?,1,1)
                """, UUID.randomUUID(), positiveRequest, goods, unit));
        assertDoesNotThrow(() -> db.update("UPDATE workshop_material_requisitions SET status='CANCELLED' WHERE id="
                + "(SELECT requisition_id FROM workshop_material_requisition_lines WHERE id=?)", line));
        assertThrows(DataAccessException.class, () -> insert("RETURN", "WORKSHOP_REQUEST", "PENDING", unit));
        assertThrows(DataAccessException.class, () -> insert("ISSUE", "WAREHOUSE_DIRECT", "PENDING", unit));
        assertThrows(DataAccessException.class, () -> insert("ISSUE", "WORKSHOP_REQUEST", "DONE", unit));
    }

    @Test
    void massActiveIdentityAndExactBaseUnitAreRequired() {
        assertThrows(DataAccessException.class, () -> insert("ISSUE", "WORKSHOP_REQUEST", "PENDING", UUID.randomUUID()));
        db.update("UPDATE unit_measurement_profiles SET measurement_dimension='COUNT'");
        assertThrows(DataAccessException.class, () -> insert("ISSUE", "WORKSHOP_REQUEST", "PENDING", unit));
        db.update("UPDATE unit_measurement_profiles SET measurement_dimension='MASS'");
        db.update("UPDATE goods SET status='停用'");
        assertThrows(DataAccessException.class, () -> insert("ISSUE", "WORKSHOP_REQUEST", "PENDING", unit));
    }

    @Test
    void alreadyPeriodicRoutesAndImmutableRequestHistoryRemain() {
        db.update("UPDATE goods SET issue_method='PERIODIC'");
        assertDoesNotThrow(() -> insert("RETURN", "WORKSHOP_REQUEST", "PENDING", unit));
        UUID line = insert("ISSUE", "WAREHOUSE_DIRECT", "PENDING", unit);
        assertThrows(DataAccessException.class, () -> db.update("UPDATE workshop_material_requisition_lines SET requested_qty=9 WHERE id=?", line));
        assertThrows(DataAccessException.class, () -> db.update("DELETE FROM workshop_material_requisition_lines WHERE id=?", line));
        assertDoesNotThrow(() -> db.update("UPDATE workshop_material_requisition_lines SET fulfilled_qty=2 WHERE id=?", line));
    }

    private UUID insert(String kind, String origin, String status, UUID snapshotUnit) {
        UUID request = UUID.randomUUID(), line = UUID.randomUUID();
        db.update("INSERT INTO workshop_material_requisitions VALUES (?,?,?,?)", request, kind, origin, status);
        db.update("INSERT INTO workshop_material_requisition_lines(id,requisition_id,goods_id,unit_id,requested_qty) VALUES (?,?,?,?,1)",
                line, request, goods, snapshotUnit);
        return line;
    }
}
