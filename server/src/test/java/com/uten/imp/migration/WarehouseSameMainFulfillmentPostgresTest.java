package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WarehouseSameMainFulfillmentPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate jdbc;
    private static UUID main;
    private static UUID plastics;
    private static UUID hardware;
    private static UUID other;

    @BeforeAll
    static void upgrade() {
        DB.start();
        Flyway.configure().dataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword())
                .locations("classpath:db/migration").target("488").load().migrate();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                DB.getJdbcUrl(),DB.getUsername(),DB.getPassword()));
        main = warehouse(null);
        plastics = warehouse(main);
        hardware = warehouse(main);
        other = warehouse(null);
        Flyway.configure().dataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword())
                .locations("classpath:db/migration").target("489").load().migrate();
    }

    private static UUID warehouse(UUID parent) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id,code,name,parent_id) VALUES (?,?,?,?)",
                id,"MAIN-" + id,"Material warehouse",parent);
        return id;
    }

    @AfterAll
    static void stop() { DB.stop(); }

    @Test
    void siblingsShareFulfillmentAndSeparateMainStaysIsolated() {
        assertThat(jdbc.queryForObject("SELECT fn_warehouse_same_main(?,?)",Boolean.class,
                plastics,hardware)).isTrue();
        assertThat(jdbc.queryForObject("SELECT fn_warehouse_same_main(?,?)",Boolean.class,
                plastics,other)).isFalse();
        assertThat(jdbc.queryForObject("SELECT fn_warehouse_main_id(?)",UUID.class,hardware))
                .isEqualTo(main);
        assertThat(jdbc.queryForObject("SELECT fn_warehouse_main_id(?)",UUID.class,other))
                .isEqualTo(other);
        assertThat(jdbc.queryForObject("SELECT fn_warehouse_same_main(?,?)",Boolean.class,
                UUID.randomUUID(),hardware)).isFalse();
        assertThat(jdbc.queryForObject("SELECT parent_id FROM warehouses WHERE id=?",
                UUID.class,plastics)).isEqualTo(main);
    }

    @Test
    void formalizationPreservesPhysicalReservationIdentityAndSourceGuards() {
        String source = jdbc.queryForObject("""
                SELECT pg_get_functiondef('fn_check_preplan_stock_entitlement_event()'::regprocedure)
                """,String.class);
        assertThat(source)
                .contains("NOT fn_warehouse_same_main(demand.warehouse_id,reservation.warehouse_id)")
                .contains("fn_analysis_plan_material_matches(production_plan.material_analysis_item_id,material.id)")
                .contains("target_reservation.warehouse_id <> reservation.warehouse_id")
                .contains("target_linked + NEW.qty > target_reservation.qty")
                .contains("invalid entitlement formal bridge");
        String stockGuard = jdbc.queryForObject("""
                SELECT pg_get_functiondef('fn_guard_production_stock_allocation()'::regprocedure)
                """,String.class);
        assertThat(stockGuard).contains("fn_warehouse_same_main(v_demand.warehouse_id,NEW.warehouse_id)");
    }
}
