package com.uten.imp.features.production.directtransfer;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Numeric query probes use temporary relation shadows; migration installation on
 * the real schema is covered by OrdinaryStorageBoundaryMigrationPostgresTest. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WorkshopDirectTransferQuantityPostgresTest {
    @Test
    void baseUnitsMixedStorageAndSplitSiblingsShareOneCoverageRule() throws Exception {
        try (var db = new PostgreSQLContainer<>("postgres:16-alpine")) {
            db.start();
            var source = new SingleConnectionDataSource(db.getJdbcUrl(), db.getUsername(), db.getPassword(), true);
            try {
                var jdbc = new JdbcTemplate(source);
                jdbc.execute("CREATE TEMP TABLE warehouses(id uuid PRIMARY KEY,is_line_side boolean)");
                jdbc.execute("CREATE TEMP TABLE production_material_demands(id uuid PRIMARY KEY,split_root_demand_id uuid)");
                jdbc.execute("CREATE TEMP TABLE production_daily_report_items(id uuid PRIMARY KEY,unit_rate numeric)");
                jdbc.execute("""
                        CREATE TEMP TABLE production_workshop_direct_transfer_items(
                            to_demand_id uuid,source_report_item_id uuid,qty numeric,reversal_id uuid)
                        """);
                jdbc.execute("""
                        CREATE TEMP TABLE stock_reservations(
                            demand_id uuid,warehouse_id uuid,qty numeric,released_qty numeric,is_deleted boolean)
                        """);
                String migration = new ClassPathResource(
                        "db/migration/V612__workshop_direct_transfer_base_quantity_coverage.sql")
                        .getContentAsString(StandardCharsets.UTF_8);
                jdbc.execute(migration.substring(0, migration.indexOf("-- 保留 V584")));

                UUID root = UUID.randomUUID(), child = UUID.randomUUID(), ordinary = UUID.randomUUID(), line = UUID.randomUUID();
                jdbc.update("INSERT INTO warehouses VALUES (?,false),(?,true)", ordinary, line);
                jdbc.update("INSERT INTO production_material_demands VALUES (?,null),(?,?)", root, child, root);
                UUID report = UUID.randomUUID();
                jdbc.update("INSERT INTO production_daily_report_items VALUES (?,10)", report);
                jdbc.update("INSERT INTO production_workshop_direct_transfer_items VALUES (?,?,4,null)", root, report);
                quantity(jdbc, root, "40"); // Four boxes of ten; never four basic units.
                jdbc.update("INSERT INTO stock_reservations VALUES (?,?,60,0,false)", root, ordinary);
                quantity(jdbc, root, "100"); // 40 direct + 60 normal; MAX(40,60) was wrong.
                jdbc.update("INSERT INTO stock_reservations VALUES (?,?,40,0,false)", root, line);
                quantity(jdbc, root, "100"); // Direct issuance is not another 40 units.
                jdbc.update("UPDATE stock_reservations SET released_qty=qty WHERE demand_id=?", root);
                jdbc.update("INSERT INTO stock_reservations VALUES (?,?,25,0,false)", child, line);
                quantity(jdbc, root, "15"); // Child already consumed 25 of the inherited 40.
                quantity(jdbc, child, "40");
                UUID fractional = UUID.randomUUID();
                jdbc.update("INSERT INTO production_daily_report_items VALUES (?,0.1)", fractional);
                jdbc.update("INSERT INTO production_workshop_direct_transfer_items VALUES (?,?,3,null)", child, fractional);
                quantity(jdbc, root, "15.3"); // Child's own 0.3 offsets its use of the shared root lot.
                quantity(jdbc, child, "40.3");
                jdbc.update("UPDATE production_workshop_direct_transfer_items SET reversal_id=? WHERE source_report_item_id=?",
                        UUID.randomUUID(), fractional);
                quantity(jdbc, root, "15");
                quantity(jdbc, child, "40");
            } finally {
                source.destroy();
            }
        }
    }

    private static void quantity(JdbcTemplate jdbc, UUID demand, String expected) {
        assertThat(jdbc.queryForObject("SELECT fn_workshop_direct_covered_base_qty(?)", BigDecimal.class, demand))
                .isEqualByComparingTo(expected);
    }
}
