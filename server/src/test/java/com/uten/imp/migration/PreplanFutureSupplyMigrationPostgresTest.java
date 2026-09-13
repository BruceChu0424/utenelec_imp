package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Current-head compilation catches PostgreSQL's rewritten view aliases before business tests. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class PreplanFutureSupplyMigrationPostgresTest {
    @Test void currentHeadCompilesPublicExpectedSupplyAndClosedPendingEta() {
        try(var database=new PostgreSQLContainer<>("postgres:16-alpine")) {
            database.start();
            var result=Flyway.configure().dataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword())
                    .locations("classpath:db/migration").load().migrate();
            assertThat(result.migrationsExecuted).isEqualTo(MigrationRehearsalSupport.CURRENT_MIGRATION_COUNT);
            var db=new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
            String definition=db.queryForObject("SELECT pg_get_viewdef('v_preplan_public_surplus_source_state'::regclass,true)",String.class);
            assertThat(definition).contains("fn_preplan_public_source_approved_capacity", "fn_preplan_public_source_open_qty",
                    "fn_procurement_order_source_pending_qty", "fn_preplan_action_received_qty");
            UUID absent=UUID.randomUUID();
            assertThat(db.queryForObject("SELECT fn_procurement_order_source_pending_qty('PURCHASE',?,?)",BigDecimal.class,absent,absent)).isEqualByComparingTo("0");
            assertThat(db.queryForObject("SELECT fn_procurement_order_source_pending_qty('SUBCONTRACT',?,?)",BigDecimal.class,absent,absent)).isEqualByComparingTo("0");
            assertThat(db.queryForObject("SELECT COUNT(*) FROM v_preplan_public_surplus_source_state",Integer.class)).isZero();
        }
    }
}
