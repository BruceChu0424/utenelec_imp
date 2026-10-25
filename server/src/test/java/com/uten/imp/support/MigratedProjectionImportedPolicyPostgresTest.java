package com.uten.imp.support;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** A native/legacy/FK counterexample prevents the projection policy becoming an all-false stub. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MigratedProjectionImportedPolicyPostgresTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate jdbc;

    @BeforeAll static void start() {
        PG.start();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        MigratedProjectionSchema.createCurrentTables(jdbc, "sales_orders", "sales_order_items", "goods");
        jdbc.execute("ALTER TABLE sales_order_items ADD CONSTRAINT fixture_order_source FOREIGN KEY(order_id) REFERENCES sales_orders(id)");
        MigratedProjectionSchema.installImportedDocumentPolicy(jdbc, "sales_orders", "sales_order_items");
    }

    @AfterAll static void stop() { PG.stop(); }

    @Test void nativeAndImportedFactsRemainDistinctThroughTheActualSourceForeignKey() {
        UUID nativeOrder = UUID.randomUUID(), importedOrder = UUID.randomUUID();
        UUID nativeItem = UUID.randomUUID(), importedItem = UUID.randomUUID();
        jdbc.update("INSERT INTO sales_orders(id,legacy_id) VALUES (?,NULL),(?,12345)", nativeOrder, importedOrder);
        jdbc.update("INSERT INTO sales_order_items(id,order_id) VALUES (?,?),(?,?)",
                nativeItem, nativeOrder, importedItem, importedOrder);
        assertThat(imported("sales_orders", nativeOrder)).isFalse();
        assertThat(imported("sales_orders", importedOrder)).isTrue();
        assertThat(imported("sales_order_items", nativeItem)).isFalse();
        assertThat(imported("sales_order_items", importedItem)).isTrue();
        assertThat(jdbc.queryForObject("SELECT fn_imported_business_document_scope_table('sales_order')", String.class))
                .isEqualTo("sales_orders");
        assertThat(jdbc.queryForObject("SELECT fn_imported_business_document_scope_table('sales_order_item')", String.class))
                .isEqualTo("sales_order_items");
    }

    @Test void unprotectedMastersAndArbitraryIdentifiersCannotBeRegisteredAsBusinessDocuments() {
        assertThatThrownBy(() -> MigratedProjectionSchema.installImportedDocumentPolicy(jdbc, "goods"))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> MigratedProjectionSchema.installImportedDocumentPolicy(jdbc, "sales_orders;DROP TABLE goods"))
                .isInstanceOf(IllegalArgumentException.class);
        assertThat(jdbc.queryForObject("SELECT fn_imported_business_document_table('goods')", Boolean.class)).isFalse();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgname='trg_00_imported_business_archive_only' AND tgenabled='A'", Integer.class))
                .isEqualTo(2);
    }

    private boolean imported(String table, UUID id) {
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT fn_imported_business_document(?,?)", Boolean.class, table, id));
    }
}
