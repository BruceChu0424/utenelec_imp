package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.DriverManager;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/** Composite row encoding is only a fixed-schema, same-transaction change detector. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionFootprintRowHashPostgresTest {
    @Test
    void wholeRowTextRetainsEveryValueAndUnambiguousNullEscapingAndArrayBoundaries() throws Exception {
        try (var postgres = new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();
            try (var connection = DriverManager.getConnection(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
                 var statement = connection.createStatement()) {
                connection.setAutoCommit(false);
                statement.execute("""
                        CREATE TEMP TABLE hash_probe(
                            nullable_text text, first_text text, second_text text,
                            quantity numeric(18,4), object_id uuid, status text,
                            active boolean, values_array text[], occurred_at timestamptz)
                        """);
                String baseline = """
                        INSERT INTO hash_probe VALUES(NULL,'中文','尾部',10,
                            '00000000-0000-0000-0000-000000000001','ACTIVE',TRUE,NULL,
                            TIMESTAMPTZ '2026-09-12 00:00:00+00')
                        """;
                for (String change : List.of(
                        "nullable_text=''", "first_text=E'逗号,括号()双引号\"反斜线\\\\换行\\n'",
                        "quantity=10.0001", "object_id='00000000-0000-0000-0000-000000000002'",
                        "status='CANCELLED'", "active=FALSE", "values_array=ARRAY[]::text[]",
                        "values_array=ARRAY['中文,括号()','引号\"',E'换行\\n']",
                        "occurred_at=occurred_at+INTERVAL '1 second'")) {
                    statement.execute("TRUNCATE hash_probe"); statement.execute(baseline);
                    String[] before = hashes(statement);
                    assertArrayEquals(before, hashes(statement));
                    statement.execute("UPDATE hash_probe SET " + change);
                    String[] after = hashes(statement);
                    assertNotEquals(before[0], after[0], "JSON must observe " + change);
                    assertNotEquals(before[1], after[1], "Whole composite must observe " + change);
                }
                statement.execute("UPDATE hash_probe SET first_text='a,b',second_text='c'");
                String[] left = hashes(statement);
                statement.execute("UPDATE hash_probe SET first_text='a',second_text='b,c'");
                assertNotEquals(left[1], hashes(statement)[1], "Quoted field boundaries cannot collapse into concatenation");
                connection.rollback();
            }
        }
    }

    private static String[] hashes(java.sql.Statement statement) throws Exception {
        try (var rows = statement.executeQuery("SELECT md5(to_jsonb(row)::text),md5(row::text) FROM hash_probe row")) {
            assertTrue(rows.next()); return new String[]{rows.getString(1), rows.getString(2)};
        }
    }
}
