package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Upgrades both genuine V607 and the observed unrecorded, partial V608 schema. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ExpenseClaimFullchainMigrationPostgresTest {

    @Test
    void v689PreservesNonemptyClaimFactsWithoutInventingPreviousSubmissionRows() throws Exception {
        try (var postgres=database()) {
            postgres.start();
            migrate(postgres,"688");
            UUID applicant=UUID.randomUUID(), first=UUID.randomUUID(), repeated=UUID.randomUUID();
            try (var connection=connection(postgres)) {
                employee(connection,applicant);
                claim(connection,first,applicant,"BX20260923000001","2026-09-23T00:00:00Z");
                claim(connection,repeated,applicant,"BX20260923000002","2026-09-23T00:00:00Z");
                for(UUID claimId:java.util.List.of(first,repeated,repeated)) {
                    execute(connection,"INSERT INTO expense_claim_events(claim_id,event_type,actor_name_snapshot) VALUES(?,'SUBMITTED','迁移申请人')",claimId);
                }
            }
            migrate(postgres,null);
            try (var connection=connection(postgres)) {
                assertThat(number(connection,"SELECT count(*) FROM expense_claims WHERE total_amount=100 AND submission_snapshot IS NULL AND previous_submission_snapshot IS NULL")).isEqualTo(2);
                assertThat(text(connection,"SELECT resubmission::text FROM expense_claims WHERE id=?",first)).isEqualTo("false");
                assertThat(text(connection,"SELECT resubmission::text FROM expense_claims WHERE id=?",repeated)).isEqualTo("true");
                assertThat(number(connection,"SELECT count(*) FROM expense_claim_events")).isEqualTo(3);
                assertThatThrownBy(()->execute(connection,"UPDATE expense_claims SET submission_snapshot='[]'::jsonb WHERE id=?",first))
                        .isInstanceOf(SQLException.class);
                assertThat(claimNumber(connection,repeated)).isEqualTo("BX20260923000002");
            }
            migrate(postgres,null);
        }
    }

    @Test
    void cleanV607MigratesThroughExpenseClaimChangesToCurrentHead() throws Exception {
        try (var postgres = database()) {
            postgres.start();
            migrate(postgres, "607");
            try (var connection = connection(postgres)) {
                assertThat(number(connection, """
                        SELECT count(*) FROM information_schema.columns
                        WHERE table_schema='public' AND table_name='expense_claims'
                          AND column_name='claim_no'
                        """)).isZero();
            }
            migrate(postgres, null);
            try (var connection = connection(postgres)) {
                assertCompletedSchema(connection);
                assertThat(number(connection, "SELECT count(*) FROM expense_claim_events")).isZero();
                assertThat(number(connection, "SELECT count(*) FROM expense_claim_invoices")).isZero();
            }
        }
    }

    @Test
    void observedPartialDdlAtV607IsCompletedWithoutRepairingHistory() throws Exception {
        try (var postgres = database()) {
            postgres.start();
            migrate(postgres, "607");
            UUID applicant = UUID.randomUUID();
            UUID invalid = UUID.randomUUID();
            UUID conflicting = UUID.randomUUID();
            try (var connection = connection(postgres)) {
                createPartialSchema(connection, true);
                assertThat(number(connection, """
                        SELECT count(*) FROM information_schema.columns
                        WHERE table_schema='public' AND table_name='expense_claim_invoices'
                        """)).isEqualTo(20);
                assertThat(number(connection, """
                        SELECT count(*) FROM pg_constraint
                        WHERE conrelid='expense_claim_invoices'::regclass
                        """)).isEqualTo(12);
                assertThat(number(connection, """
                        SELECT count(*) FROM flyway_schema_history WHERE version='608'
                        """)).isZero();
                assertThat(text(connection, "SELECT to_regclass('expense_claim_events')::text")).isNull();
                employee(connection, applicant);
                // Digit count alone is insufficient: the allocator cannot own sequence zero.
                claim(connection, invalid, applicant, "BX20260918000000", "2026-09-18T00:10:00Z");
            }
            assertThatThrownBy(() -> migrate(postgres, "608"))
                    .hasStackTraceContaining("invalid reserved expense claim date or sequence");
            try (var connection = connection(postgres)) {
                assertThat(number(connection, "SELECT count(*) FROM flyway_schema_history WHERE version='608'")).isZero();
                assertThat(claimNumber(connection, invalid)).isEqualTo("BX20260918000000");
                assertThat(number(connection, """
                        SELECT count(*) FROM business_identifier_reservations
                        WHERE normalized_identifier='BX20260918000000'
                        """)).isZero();
                execute(connection, "DELETE FROM expense_claims WHERE id=?", invalid);
                execute(connection, """
                        SELECT fn_claim_global_business_identifier(
                            'BX20260918000088','EXPENSE_CLAIM',?,NULL,'expense_claims')
                        """, UUID.randomUUID());
                claim(connection, conflicting, applicant, "BX20260918000088", "2026-09-18T00:10:00Z");
            }
            assertThatThrownBy(() -> migrate(postgres, "608"))
                    .hasStackTraceContaining("business identifier is reserved for another identity");
            try (var connection = connection(postgres)) {
                assertThat(number(connection, "SELECT count(*) FROM flyway_schema_history WHERE version='608'")).isZero();
                assertThat(claimNumber(connection, conflicting)).isEqualTo("BX20260918000088");
                execute(connection, "DELETE FROM expense_claims WHERE id=?", conflicting);
            }
            migrate(postgres, null);
            try (var connection = connection(postgres)) {
                assertCompletedSchema(connection);
                assertThat(number(connection, """
                        SELECT count(*) FROM flyway_schema_history WHERE version='608' AND success
                        """)).isEqualTo(1);
                assertThat(number(connection, """
                        SELECT count(*) FROM flyway_schema_history WHERE NOT success
                        """)).isZero();
            }
        }
    }

    @Test
    void nonemptyPartialUpgradePreservesNumbersEvidenceAndLifetimeOwnership() throws Exception {
        try (var postgres = database()) {
            postgres.start();
            migrate(postgres, "607");
            UUID applicant = UUID.randomUUID();
            UUID seven = UUID.randomUUID();
            UUID fortyOne = UUID.randomUUID();
            UUID nextDay = UUID.randomUUID();
            UUID missingFirstDay = UUID.randomUUID();
            UUID missingNextDay = UUID.randomUUID();
            UUID existingEvent = UUID.randomUUID();
            UUID invoice = UUID.randomUUID();
            try (var connection = connection(postgres)) {
                createPartialSchema(connection, false);
                employee(connection, applicant);
                // Existing document dates need not equal their creation dates. Preserve the labels.
                claim(connection, seven, applicant, "BX20260918000007", "2026-09-19T00:10:00Z");
                claim(connection, fortyOne, applicant, "BX20260918000041", "2026-09-19T00:11:00Z");
                claim(connection, nextDay, applicant, "BX20260919000300", "2026-09-18T00:10:00Z");
                claim(connection, missingFirstDay, applicant, null, "2026-09-17T18:00:00Z");
                claim(connection, missingNextDay, applicant, null, "2026-09-18T18:00:00Z");
                execute(connection, """
                        UPDATE expense_claims SET status='SUBMITTED',submitted_by=?,
                            submitted_at=TIMESTAMPTZ '2026-09-19T01:00:00Z' WHERE id=?
                        """, applicant, fortyOne);
                execute(connection, """
                        INSERT INTO business_document_sequences(namespace_key,sequence_date,last_seq)
                        VALUES('EXPENSE_CLAIM',DATE '2026-09-18',900)
                        """);
                execute(connection, """
                        SELECT fn_claim_global_business_identifier(
                            'BX20260918000777','EXPENSE_CLAIM',?,NULL,'expense_claims')
                        """, UUID.randomUUID());
                execute(connection, """
                        SELECT fn_claim_global_business_identifier(
                            'BX20260918000007','EXPENSE_CLAIM',?,NULL,'expense_claims')
                        """, seven);
                execute(connection, EVENT_TABLE_DDL);
                execute(connection, """
                        INSERT INTO expense_claim_events(id,claim_id,event_type,actor_employee_id,
                            actor_name_snapshot,remark,created_at)
                        SELECT ?,id,'CREATED',applicant_id,applicant_name_snapshot,
                            '已存在的创建证据',created_at FROM expense_claims WHERE id=?
                        """, existingEvent, seven);
                execute(connection, """
                        INSERT INTO expense_claim_invoices(id,claim_id,line_no,invoice_type,
                            invoice_no,total_amount,check_state,remark)
                        VALUES(?,?,1,'DIGITAL','26310000000000765432',100,'VERIFIED_MANUAL','已有票据')
                        """, invoice, seven);
            }
            migrate(postgres, "608");
            try (var connection = connection(postgres)) {
                assertCompletedSchema(connection);
                assertThat(claimNumber(connection, seven)).isEqualTo("BX20260918000007");
                assertThat(claimNumber(connection, fortyOne)).isEqualTo("BX20260918000041");
                assertThat(claimNumber(connection, nextDay)).isEqualTo("BX20260919000300");
                String firstNumber = claimNumber(connection, missingFirstDay);
                String secondNumber = claimNumber(connection, missingNextDay);
                assertThat(firstNumber).matches("BX20260918[0-9]{6}");
                assertThat(Long.parseLong(firstNumber.substring(10))).isGreaterThan(900);
                assertThat(secondNumber).matches("BX20260919[0-9]{6}");
                assertThat(Long.parseLong(secondNumber.substring(10))).isGreaterThan(300);
                assertThat(number(connection, "SELECT count(*) FROM expense_claim_events")).isEqualTo(6);
                assertThat(text(connection, "SELECT remark FROM expense_claim_events WHERE id=?", existingEvent))
                        .isEqualTo("已存在的创建证据");
                assertThat(text(connection, "SELECT remark FROM expense_claim_invoices WHERE id=?", invoice))
                        .isEqualTo("已有票据");
                assertThat(number(connection, """
                        SELECT count(*) FROM expense_claims c
                        JOIN business_identifier_reservation_members m
                          ON m.normalized_identifier=c.claim_no AND m.entity_id=c.id
                         AND m.owner_domain='EXPENSE_CLAIM' AND m.source_table='expense_claims'
                        """)).isEqualTo(5);
                String beforeReplay = evidenceSnapshot(connection);
                replayV608(connection);
                assertCompletedSchema(connection);
                assertThat(evidenceSnapshot(connection)).isEqualTo(beforeReplay);
                assertThat(number(connection, "SELECT count(*) FROM expense_claim_events")).isEqualTo(6);
                assertThatThrownBy(() -> execute(connection, """
                        UPDATE expense_claims SET claim_no='BX20260918000999' WHERE id=?
                        """, seven)).isInstanceOf(SQLException.class)
                        .satisfies(failure -> assertThat(((SQLException) failure).getSQLState()).isEqualTo("23514"));
                execute(connection, "DELETE FROM expense_claims WHERE id=?", missingFirstDay);
                assertThat(number(connection, """
                        SELECT count(*) FROM business_identifier_reservations WHERE normalized_identifier=?
                        """, firstNumber)).isEqualTo(1);
                assertThatThrownBy(() -> claim(connection, UUID.randomUUID(), applicant,
                        firstNumber, "2026-09-17T18:00:00Z"))
                        .isInstanceOf(SQLException.class)
                        .satisfies(failure -> assertThat(((SQLException) failure).getSQLState()).isEqualTo("23505"));
            }
            migrate(postgres, null);
            try (var connection = connection(postgres)) {
                assertCompletedSchema(connection);
                assertThat(number(connection, "SELECT count(*) FROM expense_claim_events")).isEqualTo(5);
                assertThat(text(connection, "SELECT check_state FROM expense_claim_invoices WHERE id=?", invoice))
                        .isEqualTo("AMOUNTS_MATCH");
                assertThat(claimNumber(connection, seven)).isEqualTo("BX20260918000007");
            }
        }
    }

    private static void assertCompletedSchema(Connection connection) throws SQLException {
        assertThat(text(connection, """
                SELECT is_nullable FROM information_schema.columns
                WHERE table_schema='public' AND table_name='expense_claims' AND column_name='claim_no'
                """)).isEqualTo("NO");
        assertThat(number(connection, """
                SELECT count(*) FROM business_identifier_namespaces WHERE namespace_key='EXPENSE_CLAIM'
                  AND identifier_family='DOCUMENT' AND fixed_prefix='BX'
                  AND source_table='expense_claims' AND identifier_column='claim_no'
                """)).isEqualTo(1);
        assertThat(number(connection, """
                SELECT count(*) FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                WHERE t.tgrelid='expense_claims'::regclass AND NOT t.tgisinternal
                  AND p.proname='fn_reserve_business_document_identifier' AND t.tgenabled<>'D'
                """)).isEqualTo(1);
        // V670(ADR-105)之前每表恰一个全表审计触发器; 之后按三清单: 报销发票是 FULL
        // (行事件 + 带 WHEN 的更新两个触发器), 报销事件账是只追加、带操作人的事件表(NONE)。
        boolean threeLists = number(connection,
                "SELECT count(*) FROM flyway_schema_history WHERE version='670' AND success") > 0;
        for (String table : new String[]{"expense_claim_invoices", "expense_claim_events"}) {
            assertThat(number(connection, """
                    SELECT count(*) FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                    WHERE t.tgrelid=?::regclass AND NOT t.tgisinternal
                      AND p.proname='fn_audit' AND t.tgenabled='A'
                    """, table)).isEqualTo(!threeLists ? 1 : "expense_claim_invoices".equals(table) ? 2 : 0);
            assertThat(text(connection, "SELECT pg_get_functiondef('business_data_reset()'::regprocedure)"))
                    .contains("('" + table + "', 'CLEAR')");
        }
    }

    private static void createPartialSchema(Connection connection, boolean requiredNumber) throws SQLException {
        execute(connection, """
                INSERT INTO business_identifier_namespaces(namespace_key,identifier_family,fixed_prefix,
                    source_table,identifier_column,discriminator_value)
                VALUES('EXPENSE_CLAIM','DOCUMENT','BX','expense_claims','claim_no',NULL)
                """);
        execute(connection, "ALTER TABLE expense_claims ADD COLUMN claim_no TEXT" + (requiredNumber ? " NOT NULL" : ""));
        execute(connection, """
                ALTER TABLE expense_claims
                    ADD CONSTRAINT expense_claims_claim_no_uk UNIQUE(claim_no),
                    ADD CONSTRAINT expense_claims_claim_no_chk CHECK(claim_no ~ '^BX[0-9]{14}$')
                """);
        execute(connection, INVOICE_TABLE_DDL);
        execute(connection, """
                CREATE UNIQUE INDEX expense_claim_invoices_dedup_uq
                    ON expense_claim_invoices(COALESCE(invoice_code,''),invoice_no)
                """);
        execute(connection, "CREATE INDEX idx_expense_claim_invoices_claim ON expense_claim_invoices(claim_id,line_no)");
    }

    // Fixed fixture of the observed pre-Flyway invoice table, independent of the repaired migration text.
    private static final String INVOICE_TABLE_DDL = historicalInvoiceTable();

    private static String historicalInvoiceTable() {
        try {
            return new org.springframework.core.io.ClassPathResource(
                    "migration-fixtures/expense_claim_invoices_pre_v608.sql")
                    .getContentAsString(StandardCharsets.UTF_8);
        } catch (java.io.IOException failure) {
            throw new java.io.UncheckedIOException(failure);
        }
    }

    private static final String EVENT_TABLE_DDL = """
            CREATE TABLE expense_claim_events (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                claim_id UUID NOT NULL REFERENCES expense_claims(id) ON DELETE CASCADE,
                event_type TEXT NOT NULL,actor_employee_id UUID REFERENCES employees(id) ON DELETE RESTRICT,
                actor_name_snapshot TEXT NOT NULL,remark TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,created_by UUID,updated_by UUID,
                CONSTRAINT expense_claim_events_type_chk CHECK(event_type IN
                    ('CREATED','SUBMITTED','WITHDRAWN','EDITED','APPROVED','REJECTED','PAID')),
                CONSTRAINT expense_claim_events_text_len_chk CHECK(char_length(actor_name_snapshot) BETWEEN 1 AND 100
                    AND (remark IS NULL OR char_length(remark)<=1000))
            )
            """;

    private static PostgreSQLContainer<?> database() {
        return new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName("expense_migration").withUsername("uten").withPassword("uten");
    }

    private static void migrate(PostgreSQLContainer<?> postgres, String target) {
        var config = Flyway.configure().dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                .locations("classpath:db/migration");
        if (target != null) config.target(target);
        config.load().migrate();
    }

    private static Connection connection(PostgreSQLContainer<?> postgres) throws SQLException {
        return DriverManager.getConnection(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
    }

    private static void employee(Connection connection, UUID id) throws SQLException {
        execute(connection, """
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,'迁移申请人','其他',
                    (SELECT id FROM departments WHERE code='DEPT_FIN' AND NOT is_deleted),
                    DATE '2026-01-01','active','regular')
                """, id, "EXP-MIG-" + id);
    }

    private static String evidenceSnapshot(Connection connection) throws SQLException {
        return text(connection, """
                SELECT jsonb_build_object(
                    'claims',(SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM expense_claims c),
                    'invoices',(SELECT jsonb_agg(to_jsonb(i) ORDER BY id) FROM expense_claim_invoices i),
                    'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM expense_claim_events e),
                    'sequences',(SELECT jsonb_agg(to_jsonb(s) ORDER BY sequence_date)
                        FROM business_document_sequences s WHERE namespace_key='EXPENSE_CLAIM'))::text
                """);
    }

    private static void replayV608(Connection connection) throws Exception {
        try (var resource = ExpenseClaimFullchainMigrationPostgresTest.class.getResourceAsStream(
                "/db/migration/V608__expense_claim_fullchain.sql")) {
            assertThat(resource).isNotNull();
            connection.setAutoCommit(false);
            try (var statement = connection.createStatement()) {
                statement.execute(new String(resource.readAllBytes(), StandardCharsets.UTF_8));
                connection.commit();
            } catch (Exception failure) {
                connection.rollback();
                throw failure;
            } finally {
                connection.setAutoCommit(true);
            }
        }
    }

    private static void claim(Connection connection, UUID id, UUID applicant, String number, String createdAt) throws SQLException {
        execute(connection, """
                INSERT INTO expense_claims(id,applicant_id,applicant_name_snapshot,title,total_amount,claim_no,created_at)
                VALUES(?,?,'迁移申请人','迁移历史报销',100,?,?::timestamptz)
                """, id, applicant, number, createdAt);
    }

    private static String claimNumber(Connection connection, UUID id) throws SQLException {
        return text(connection, "SELECT claim_no FROM expense_claims WHERE id=?", id);
    }

    private static void execute(Connection connection, String sql, Object... parameters) throws SQLException {
        try (var statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < parameters.length; index++) statement.setObject(index + 1, parameters[index]);
            statement.execute();
        }
    }

    private static String text(Connection connection, String sql, Object... parameters) throws SQLException {
        try (var statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < parameters.length; index++) statement.setObject(index + 1, parameters[index]);
            try (var rows = statement.executeQuery()) {
                assertThat(rows.next()).isTrue();
                return rows.getString(1);
            }
        }
    }

    private static long number(Connection connection, String sql, Object... parameters) throws SQLException {
        return Long.parseLong(text(connection, sql, parameters));
    }
}
