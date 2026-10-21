package com.uten.imp.migration;

import com.uten.imp.testsupport.BoundTestSql;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class OrdinaryStorageBoundaryMigrationPostgresTest {
    @Test
    void upgradesHistoricalDefaultsAndProtectsBothSidesOfStorageIdentity() throws Exception {
        try (var db = new PostgreSQLContainer("postgres:16-alpine")) {
            db.start();
            com.uten.imp.testsupport.TestFlyway.configure().dataSource(db.getJdbcUrl(), db.getUsername(), db.getPassword())
                    .locations("classpath:db/migration").target("608").load().migrate();
            var jdbc = new JdbcTemplate(new DriverManagerDataSource(
                    db.getJdbcUrl(), db.getUsername(), db.getPassword()));
            UUID workshop = jdbc.queryForObject("""
                    SELECT child.id FROM departments child
                    JOIN departments parent ON parent.id = child.parent_id
                    WHERE parent.code = 'DEPT_PROD' AND NOT child.is_deleted LIMIT 1
                    """, UUID.class);
            UUID ordinary = warehouse(jdbc, "ordinary", false, null);
            UUID newer = warehouse(jdbc, "newer", false, null);
            UUID line = warehouse(jdbc, "line", true, workshop);
            UUID latestInbound = goods(jdbc, "latest-inbound", line);
            UUID fromBalance = goods(jdbc, "from-balance", line);
            UUID unknown = goods(jdbc, "unknown", line);
            UUID preserved = goods(jdbc, "preserved", ordinary);
            // Restore a pre-upgrade ledger snapshot. Cost/event facts are outside this
            // migration; historical rows are seeded on one connection with triggers off.
            jdbc.execute((org.springframework.jdbc.core.ConnectionCallback<Void>) connection -> {
                try (var statement = connection.createStatement()) {
                    statement.execute("SET session_replication_role = replica");
                    BoundTestSql.execute(statement, "INSERT INTO stock_movements(goods_id,warehouse_id,transaction_date,movement_type,source_doc_type,direction,qty) VALUES (?,?,'2026-09-01',11,'OTHER_IN',1,10), (?,?,'2026-09-02',11,'OTHER_IN',1,5), (?,?,'2026-09-03',11,'OTHER_IN',1,3)", latestInbound, ordinary, latestInbound, newer, latestInbound, line);
                    BoundTestSql.execute(statement, "INSERT INTO stock_balances(goods_id,warehouse_id,qty) VALUES (?,?,10), (?,?,20), (?,?,99)", fromBalance, ordinary, fromBalance, newer, unknown, line);
                    statement.execute("SET session_replication_role = origin");
                }
                return null;
            });
            long movementCount = jdbc.queryForObject("SELECT count(*) FROM stock_movements", Long.class);
            long balanceCount = jdbc.queryForObject("SELECT count(*) FROM stock_balances", Long.class);
            String migration = new ClassPathResource(
                    "db/migration/V610__ordinary_storage_and_workshop_location_boundary.sql")
                    .getContentAsString(StandardCharsets.UTF_8);
            jdbc.execute(migration);
            jdbc.execute(new ClassPathResource(
                    "db/migration/V612__workshop_direct_transfer_base_quantity_coverage.sql")
                    .getContentAsString(StandardCharsets.UTF_8));
            jdbc.execute(new ClassPathResource(
                    "db/migration/V613__operational_warehouse_leaf_identity.sql")
                    .getContentAsString(StandardCharsets.UTF_8));

            assertThat(owner(jdbc, latestInbound)).isEqualTo(newer);
            assertThat(owner(jdbc, fromBalance)).isEqualTo(newer);
            assertThat(owner(jdbc, unknown)).isNull();
            assertThat(owner(jdbc, preserved)).isEqualTo(ordinary);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM stock_movements", Long.class))
                    .isEqualTo(movementCount);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM stock_balances", Long.class))
                    .isEqualTo(balanceCount);
            assertThatThrownBy(() -> jdbc.update(
                    "UPDATE goods SET owning_warehouse_id=? WHERE id=?", line, preserved))
                    .hasMessageContaining("goods owning warehouse must be ordinary storage");
            assertThatThrownBy(() -> jdbc.update(
                    "UPDATE warehouses SET is_line_side=false WHERE id=?", line))
                    .hasMessageContaining("with stock or transfer history cannot change identity");
            assertThatThrownBy(() -> jdbc.update(
                    "UPDATE warehouses SET is_line_side=true,workshop_department_id=? WHERE id=?",
                    workshop, ordinary)).hasMessageContaining("cannot become a workshop transfer location");
            assertThatThrownBy(() -> jdbc.update(
                    "UPDATE warehouses SET parent_id=? WHERE id=?", line, ordinary))
                    .hasMessageContaining("must remain a leaf");
            jdbc.update("UPDATE warehouses SET status='禁用' WHERE id=?", line);
            assertThat(jdbc.queryForObject("SELECT is_line_side FROM warehouses WHERE id=?", Boolean.class, line))
                    .isTrue();

            UUID technicalChild = warehouse(jdbc, "ordinary-child-line", true, workshop);
            jdbc.update("UPDATE warehouses SET parent_id=? WHERE id=?", ordinary, technicalChild);
            assertThat(jdbc.queryForObject("SELECT fn_warehouse_is_active_accounting_leaf(?)", Boolean.class, ordinary))
                    .isTrue();
            assertThat(jdbc.queryForObject("SELECT fn_warehouse_is_active_accounting_leaf(?)", Boolean.class, technicalChild))
                    .isFalse();
            // Run the real inbound/outbound guard functions against minimal temporary
            // event rows; the historical stock above stays on its original UUID.
            jdbc.execute((org.springframework.jdbc.core.ConnectionCallback<Void>) connection -> {
                try (var statement = connection.createStatement()) {
                    statement.execute("CREATE TEMP TABLE warehouse_inbound_probe(warehouse_id uuid)");
                    statement.execute("CREATE TRIGGER guard BEFORE INSERT ON warehouse_inbound_probe "
                            + "FOR EACH ROW EXECUTE FUNCTION fn_guard_iqc_actual_warehouse_selection()");
                    BoundTestSql.execute(statement, "INSERT INTO warehouse_inbound_probe VALUES (?)", ordinary);
                    statement.execute("CREATE TEMP TABLE warehouse_outbound_probe AS SELECT * FROM sales_shipments WITH NO DATA");
                    statement.execute("CREATE TRIGGER guard BEFORE INSERT OR UPDATE ON warehouse_outbound_probe "
                            + "FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_shipment_picking_warehouse()");
                    BoundTestSql.execute(statement, "INSERT INTO warehouse_outbound_probe(warehouse_id,warehouse_chosen_at_pick,shipment_kind,status,warehouse_work_status,finance_audit,review_revision) VALUES (?,true,'CUSTOMER',0,'PENDING_PICK',1,0)", ordinary);
                    statement.execute("UPDATE warehouse_outbound_probe SET status=1,warehouse_work_status='SHIPPED'");
                }
                return null;
            });
            assertThat(jdbc.queryForObject("SELECT count(*) FROM stock_movements", Long.class)).isEqualTo(movementCount);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM stock_balances", Long.class)).isEqualTo(balanceCount);
            verifyReceivingLifecycleGuard(jdbc, ordinary, technicalChild, workshop, preserved);
        }
    }

    /** Exercise the installed direct-transfer trigger against temporary snapshots
     * of the real table shapes, including stale candidates and inactive reversals. */
    private static void verifyReceivingLifecycleGuard(
            JdbcTemplate jdbc, UUID ordinary, UUID lineSide, UUID workshop, UUID goods) {
        jdbc.execute((org.springframework.jdbc.core.ConnectionCallback<Void>) connection -> {
            try (var statement = connection.createStatement()) {
                for (String table : java.util.List.of("production_plans", "production_planning_packages",
                        "production_execution_segments", "production_material_demands", "production_daily_report_items",
                        "production_workshop_direct_transfers", "production_workshop_direct_transfer_items", "stock_reservations")) {
                    statement.execute("CREATE TEMP TABLE " + table + " AS SELECT * FROM public." + table + " WITH NO DATA");
                }
                UUID plan = UUID.randomUUID(), pack = UUID.randomUUID(), receiving = UUID.randomUUID();
                UUID producing = UUID.randomUUID(), demand = UUID.randomUUID(), reportItem = UUID.randomUUID();
                UUID transfer = UUID.randomUUID();
                BoundTestSql.execute(statement, "INSERT INTO production_plans(id,status,is_deleted,is_stopped,is_closed,is_canceled) VALUES (?,1,false,false,false,false)", plan);
                BoundTestSql.execute(statement, "INSERT INTO production_planning_packages(id,plan_id,status,is_deleted) VALUES (?,?,'CONFIRMED',false)", pack, plan);
                BoundTestSql.execute(statement, "INSERT INTO production_execution_segments(id,plan_id,package_id,workshop_department_id,status,continuous_supply,is_deleted) VALUES (?,?,?,?,'WAITING',false,false), (?,?,?,?,'IN_PROGRESS',false,false)", receiving, plan, pack, workshop, producing, plan, pack, workshop);
                BoundTestSql.execute(statement, "INSERT INTO production_material_demands(id,execution_segment_id,goods_id,warehouse_id,required_qty,status,is_deleted) VALUES (?,?,?,?,100,'OPEN',false)", demand, receiving, goods, ordinary);
                BoundTestSql.execute(statement, "INSERT INTO production_daily_report_items(id,execution_segment_id,goods_id,destination,qty,unit_rate,is_deleted) VALUES (?,?,?,'WORKSHOP',2,1,false)", reportItem, producing, goods);
                BoundTestSql.execute(statement, "INSERT INTO production_workshop_direct_transfers(id,line_side_warehouse_id,workshop_department_id) VALUES (?,?,?)", transfer, lineSide, workshop);
                statement.execute("CREATE TRIGGER guard BEFORE INSERT OR UPDATE OR DELETE ON production_workshop_direct_transfer_items "
                        + "FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_direct_transfer_item()");
                String insert = "INSERT INTO production_workshop_direct_transfer_items(transfer_id,source_report_item_id,"
                        + "to_execution_segment_id,to_demand_id,qty) VALUES (?,?,?,?,2)";
                for (String[] change : java.util.List.of(
                        new String[]{"production_plans", "UPDATE production_plans SET is_stopped=true", "UPDATE production_plans SET is_stopped=false"},
                        new String[]{"production_plans", "UPDATE production_plans SET is_closed=true", "UPDATE production_plans SET is_closed=false"},
                        new String[]{"production_plans", "UPDATE production_plans SET is_canceled=true", "UPDATE production_plans SET is_canceled=false"},
                        new String[]{"production_plans", "UPDATE production_plans SET is_deleted=true", "UPDATE production_plans SET is_deleted=false"},
                        new String[]{"production_plans", "UPDATE production_plans SET status=0", "UPDATE production_plans SET status=1"},
                        new String[]{"production_planning_packages", "UPDATE production_planning_packages SET status='DRAFT'", "UPDATE production_planning_packages SET status='CONFIRMED'"},
                        new String[]{"production_planning_packages", "UPDATE production_planning_packages SET is_deleted=true", "UPDATE production_planning_packages SET is_deleted=false"},
                        new String[]{"production_execution_segments", "UPDATE production_execution_segments SET status='IN_PROGRESS'", "UPDATE production_execution_segments SET status='WAITING'"},
                        new String[]{"production_execution_segments", "UPDATE production_execution_segments SET status='COMPLETED'", "UPDATE production_execution_segments SET status='WAITING'"},
                        new String[]{"production_execution_segments", "UPDATE production_execution_segments SET status='CANCELLED'", "UPDATE production_execution_segments SET status='WAITING'"},
                        new String[]{"production_execution_segments", "UPDATE production_execution_segments SET is_deleted=true", "UPDATE production_execution_segments SET is_deleted=false"})) {
                    statement.execute(change[1]);
                    assertThatThrownBy(() -> BoundTestSql.execute(statement, insert, transfer, reportItem, receiving, demand))
                            .as("reject stale recipient: %s %s", change[0], change[1])
                            .hasMessageContaining("requires an active receiving plan, package and execution task");
                    statement.execute(change[2]);
                }
                for (String state : java.util.List.of("WAITING", "READY", "DISPATCHED", "IN_PROGRESS")) {
                    BoundTestSql.execute(statement, "UPDATE production_execution_segments SET status=?,continuous_supply=? WHERE id=?",
                            state, state.equals("IN_PROGRESS"), receiving);
                    BoundTestSql.execute(statement, insert, transfer, reportItem, receiving, demand);
                    statement.execute("UPDATE production_plans SET is_stopped=true,is_closed=true");
                    BoundTestSql.execute(statement, "UPDATE production_workshop_direct_transfer_items SET reversal_id=? WHERE reversal_id IS NULL", UUID.randomUUID());
                    statement.execute("UPDATE production_plans SET is_stopped=false,is_closed=false");
                }
            }
            return null;
        });
    }

    private static UUID warehouse(JdbcTemplate jdbc, String label, boolean lineSide, UUID workshop) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO warehouses(id,code,name,status,is_accountable,is_line_side,workshop_department_id)
                VALUES (?,?,?,'使用',true,?,?)
                """, id, "V610-" + label, label, lineSide, workshop);
        return id;
    }

    private static UUID goods(JdbcTemplate jdbc, String label, UUID owner) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name,owning_warehouse_id,code_sequence) "
                        + "VALUES (?,?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                id, "V610-" + label, label, owner);
        return id;
    }

    private static UUID owner(JdbcTemplate jdbc, UUID goods) {
        return jdbc.queryForObject("SELECT owning_warehouse_id FROM goods WHERE id=?", UUID.class, goods);
    }
}
