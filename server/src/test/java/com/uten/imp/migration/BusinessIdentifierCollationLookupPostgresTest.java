package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Non-C database evidence for the collation inherited by trigger arguments. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class BusinessIdentifierCollationLookupPostgresTest {
    private static final PostgreSQLContainer<?> DATABASE =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withEnv("POSTGRES_INITDB_ARGS", "--locale=en_US.utf8");
    private static JdbcTemplate jdbc;
    private static TransactionTemplate transactions;
    private static String beforeDigest;
    private static String afterDigest;
    private static String unindexedPlan;

    @BeforeAll
    static void prepareRealReservedHistory() throws Exception {
        DATABASE.start();
        // This index-only change is independent of the V500 valuation work.
        // Freeze the existing nonempty authority first, then apply exactly V501.
        Flyway.configure().dataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword())
                .locations("classpath:db/migration").target("499").load().migrate();
        var dataSource = new DriverManagerDataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        transactions = new TransactionTemplate(new JdbcTransactionManager(dataSource));
        assertThat(jdbc.queryForObject("SELECT datcollate FROM pg_database WHERE datname=current_database()", String.class))
                .isNotEqualTo("C");
        jdbc.execute("""
                INSERT INTO business_identifier_reservations
                    (normalized_identifier,first_identifier_snapshot,first_owner_domain,first_entity_id)
                SELECT 'HISTORY-'||lpad(n::text,6,'0'),'HISTORY-'||lpad(n::text,6,'0'),
                    'SALES_ORDER',md5('history-entity-'||n)::uuid
                FROM generate_series(1,20000) source(n)
                """);
        jdbc.execute("""
                INSERT INTO business_identifier_reservation_members
                    (normalized_identifier,owner_domain,entity_id,identifier_snapshot,source_table)
                SELECT normalized_identifier,first_owner_domain,first_entity_id,first_identifier_snapshot,'sales_orders'
                FROM business_identifier_reservations WHERE normalized_identifier LIKE 'HISTORY-%'
                """);
        jdbc.execute("""
                INSERT INTO business_prefix_reservations
                    (normalized_prefix,first_prefix_snapshot,first_owner_kind,first_owner_key)
                SELECT 'P'||lpad(n::text,7,'0'),'P'||lpad(n::text,7,'0'),'CATEGORY','history/'||n
                FROM generate_series(1,20000) source(n)
                """);
        jdbc.execute("""
                INSERT INTO business_prefix_reservation_members
                    (normalized_prefix,owner_kind,owner_key,prefix_snapshot,member_kind)
                SELECT normalized_prefix,first_owner_kind,first_owner_key,first_prefix_snapshot,'HISTORICAL'
                FROM business_prefix_reservations WHERE first_owner_key LIKE 'history/%'
                """);
        jdbc.execute("ANALYZE business_identifier_reservations");
        jdbc.execute("ANALYZE business_identifier_reservation_members");
        jdbc.execute("ANALYZE business_prefix_reservations");
        jdbc.execute("ANALYZE business_prefix_reservation_members");
        beforeDigest = digest();
        unindexedPlan = plan("SELECT 1 FROM business_identifier_reservations WHERE normalized_identifier='HISTORY-NOT-THERE'::text COLLATE \"C\" FOR UPDATE");
        transactions.executeWithoutResult(status -> {
            try {
                jdbc.execute(Files.readString(Path.of("src/main/resources/db/migration/V501__business_identifier_c_collation_lookup_indexes.sql")));
            } catch (java.io.IOException error) { throw new IllegalStateException(error); }
        });
        afterDigest = digest();
    }

    @AfterAll
    static void stop() { DATABASE.stop(); }

    @Test
    void migrationKeepsEveryHistoricalIdentifierAndOwnerByte() {
        assertThat(afterDigest).isEqualTo(beforeDigest);
        assertThat(unindexedPlan).contains("Seq Scan on business_identifier_reservations");
    }

    @Test
    void triggerCollationUsesPointIndexesForAllFourAuthorityLookups() {
        assertUses("SELECT 1 FROM business_identifier_reservations WHERE normalized_identifier='HISTORY-NOT-THERE'::text COLLATE \"C\" FOR UPDATE",
                "idx_business_identifier_reserved_c_lookup", "business_identifier_reservations");
        assertUses("SELECT 1 FROM business_identifier_reservation_members WHERE normalized_identifier='HISTORY-NOT-THERE'::text COLLATE \"C\" AND owner_domain='SALES_ORDER'::text COLLATE \"C\"",
                "idx_business_identifier_members_c_lookup", "business_identifier_reservation_members");
        assertUses("SELECT 1 FROM business_prefix_reservations WHERE normalized_prefix='P9999999'::text COLLATE \"C\" FOR UPDATE",
                "idx_business_prefix_reserved_c_lookup", "business_prefix_reservations");
        assertUses("SELECT 1 FROM business_prefix_reservation_members WHERE normalized_prefix='P9999999'::text COLLATE \"C\" AND owner_kind='CATEGORY'::text COLLATE \"C\"",
                "idx_business_prefix_members_c_lookup", "business_prefix_reservation_members");
    }

    @Test
    void canonicalGlobalOwnershipStillRejectsReuseAndAllowsTheSameIdentity() {
        UUID owner = jdbc.queryForObject("SELECT first_entity_id FROM business_identifier_reservations WHERE normalized_identifier='HISTORY-000001'", UUID.class);
        transactions.executeWithoutResult(status -> {
            jdbc.queryForObject("SELECT fn_claim_global_business_identifier('HISTORY-000001'::text COLLATE \"C\",'SALES_ORDER',?,NULL,'sales_orders','HISTORY-000001',false,false)::text", String.class, owner);
        });
        assertThatThrownBy(() -> transactions.executeWithoutResult(status ->
                jdbc.queryForObject("SELECT fn_claim_global_business_identifier('HISTORY-000001'::text COLLATE \"C\",'SALES_ORDER',?,NULL,'sales_orders',NULL,false,false)::text", String.class, UUID.randomUUID())))
                .hasMessageContaining("business identifier is reserved for another identity");
        assertThatThrownBy(() -> transactions.executeWithoutResult(status ->
                jdbc.queryForObject("SELECT fn_claim_global_business_prefix('P0000001'::text COLLATE \"C\",'CATEGORY','different-owner',NULL,NULL,'P0000001','CATEGORY',NULL,false)::text", String.class)))
                .hasMessageContaining("business prefix is reserved for another owner");
        assertThat(digest()).isEqualTo(afterDigest);
    }

    private static void assertUses(String sql, String index, String table) {
        assertThat(plan(sql)).contains(index).doesNotContain("Seq Scan on " + table);
    }
    private static String plan(String sql) {
        return String.join("\n",jdbc.queryForList("EXPLAIN (ANALYZE, BUFFERS) " + sql,String.class));
    }
    private static String digest() {
        var value = new StringBuilder();
        for (String table : new String[]{"business_identifier_reservations", "business_identifier_reservation_members", "business_prefix_reservations", "business_prefix_reservation_members"}) {
            value.append(table).append(':').append(jdbc.queryForObject(
                    "SELECT count(*)::text||':'||md5(coalesce(string_agg(to_jsonb(t)::text,E'\\n' ORDER BY to_jsonb(t)::text),'')) FROM " + table + " t", String.class)).append(';');
        }
        return value.toString();
    }
}
