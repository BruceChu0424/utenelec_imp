package com.uten.imp.features.ai.job;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Real current-schema cleanup boundaries; no business database or external AI provider. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AiJobRetentionPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static DriverManagerDataSource source;
    private static JdbcTemplate jdbc;
    private static AiJobRepository jobs;

    @BeforeAll static void open() throws SQLException {
        database = MigratedSchemaBaseline.openDatabase("ai_job_retention");
        source = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword());
        jdbc = new JdbcTemplate(source);
        jobs = new AiJobRepository(new NamedParameterJdbcTemplate(source));
    }

    @AfterAll static void close() throws SQLException {
        if (database != null) database.close();
    }

    @BeforeEach void emptyPrivateFixture() {
        jdbc.execute("TRUNCATE ai_jobs CASCADE");
    }

    @ParameterizedTest
    @ValueSource(strings = {"SUCCEEDED", "FAILED", "CANCELLED"})
    void retentionStartsAtCompletionNotAtUpload(String status) {
        UUID recent = job(status, "now() - interval '1 hour'", false);
        UUID expired = job(status, "now() - interval '8 days'", false);

        assertThat(jobs.deleteFinishedOlderThan(7)).isEqualTo(1);
        assertThat(exists(recent)).as("an old upload just reached its terminal state").isTrue();
        assertThat(exists(expired)).isFalse();
    }

    @Test void aStaleQueueFailureIsRetainedForItsOwnFullFailureWindow() {
        UUID queued = job("PENDING", "NULL", false);
        jdbc.update("UPDATE ai_jobs SET updated_at=created_at WHERE id=?",queued);
        assertThat(jobs.failStalePending(30)).isEqualTo(1);
        assertThat(jobs.deleteFinishedOlderThan(7)).isZero();
        assertThat(jdbc.queryForObject("SELECT status || ':' || error_code FROM ai_jobs WHERE id=?",
                String.class, queued)).isEqualTo("FAILED:QUEUE_TIMEOUT");
    }

    @Test void missingOrFutureCompletionAndActiveJobsAreNeverAgeGuessed() {
        UUID missing = job("FAILED", "NULL", false);
        UUID future = job("CANCELLED", "now() + interval '1 day'", false);
        UUID pending = job("PENDING", "now() - interval '9 days'", false);
        UUID running = job("RUNNING", "now() - interval '9 days'", false);
        assertThat(jobs.deleteFinishedOlderThan(7)).isZero();
        assertThat(java.util.List.of(missing, future, pending, running)).allMatch(this::exists);
    }

    @Test void shorterRowRetentionCannotBypassTheResultRetentionPolicy() {
        UUID retained = job("SUCCEEDED", "now() - interval '8 days'", true);
        assertThat(jobs.purgeResults(14 * 24)).isZero();
        assertThat(jobs.deleteFinishedOlderThan(7)).isZero();
        assertThat(exists(retained)).isTrue();

        // The result policy, not the row policy, authorizes discarding the payload.
        assertThat(jobs.purgeResults(48)).isEqualTo(1);
        assertThat(jobs.deleteFinishedOlderThan(7)).isEqualTo(1);
        assertThat(exists(retained)).isFalse();
    }

    @Test void completionBeforeUploadIsRetainedForReviewRatherThanAgeGuessed() {
        UUID contradictory = job("FAILED", "now() - interval '8 days'", false);
        jdbc.update("UPDATE ai_jobs SET created_at=now() WHERE id=?", contradictory);
        assertThat(jobs.deleteFinishedOlderThan(7)).isZero();
        assertThat(exists(contradictory)).isTrue();
    }

    @Test void liveLearningRetryProtectsTheRowEvenAfterItsPayloadWasCleared() {
        UUID reserved = job("SUCCEEDED", "now() - interval '8 days'", false);
        UUID expired = job("SUCCEEDED", "now() - interval '8 days'", false);
        jdbc.update("UPDATE ai_jobs SET learning_retry_until=now()+interval '1 day' WHERE id=?", reserved);
        jdbc.update("UPDATE ai_jobs SET learning_retry_until=now()-interval '1 second' WHERE id=?", expired);
        assertThat(jobs.deleteFinishedOlderThan(7)).isEqualTo(1);
        assertThat(exists(reserved)).isTrue();
        assertThat(exists(expired)).isFalse();
    }

    @Test void lockedRowsDoNotBlockCleanupOrLoseAnInFlightRetentionExtension() throws Exception {
        UUID reserved = job("SUCCEEDED", "now() - interval '8 days'", false);
        UUID expired = job("FAILED", "now() - interval '8 days'", false);
        try (Connection owner = source.getConnection()) {
            owner.setAutoCommit(false);
            try (var update = owner.prepareStatement(
                    "UPDATE ai_jobs SET learning_retry_until=now()+interval '1 day' WHERE id=?")) {
                update.setObject(1, reserved);
                update.executeUpdate();
            }
            try {
                var tx = new TransactionTemplate(new DataSourceTransactionManager(source));
                Integer removed = tx.execute(status -> {
                    jdbc.execute("SET LOCAL statement_timeout='750ms'");
                    return jobs.deleteFinishedOlderThan(7);
                });
                assertThat(removed).isEqualTo(1);
                owner.commit();
            } finally {
                owner.rollback();
            }
        }
        assertThat(exists(reserved)).isTrue();
        assertThat(exists(expired)).isFalse();
        assertThat(jobs.deleteFinishedOlderThan(7)).isZero();
    }

    @Test void everyTransactionDeletesAtMostOneThousandEligibleRows() {
        jdbc.update("""
                INSERT INTO ai_jobs(id,kind,status,input_name,input_content_type,input_kind,input_size,input_sha256,
                    submitted_by_user,submitted_auth_version,created_at,finished_at)
                SELECT gen_random_uuid(),'RETENTION_TEST','FAILED','test.csv','text/csv','CSV',0,repeat('a',64),
                    gen_random_uuid(),0,now()-interval '30 days',now()-interval '8 days'
                FROM generate_series(1,1001)
                """);
        assertThat(jobs.deleteFinishedOlderThan(7)).isEqualTo(1000);
        assertThat(jobs.deleteFinishedOlderThan(7)).isEqualTo(1);
        assertThat(jobs.deleteFinishedOlderThan(7)).isZero();
    }

    @Test void aRecoveredQueueGetsItsOwnWaitingWindowRatherThanTheOldUploadAge() {
        UUID recovered=job("PENDING","NULL",false);
        jdbc.update("UPDATE ai_jobs SET attempts=1,updated_at=now() WHERE id=?",recovered);
        assertThat(jobs.failStalePending(30)).isZero();
        assertThat(jdbc.queryForObject("SELECT status FROM ai_jobs WHERE id=?",String.class,recovered)).isEqualTo("PENDING");
    }

    @Test void resultExpiryCannotClearActiveOrContradictoryTerminalFacts() {
        UUID active=job("RUNNING","now()-interval '9 days'",true);
        UUID contradictory=job("SUCCEEDED","now()-interval '9 days'",true);
        jdbc.update("UPDATE ai_jobs SET created_at=now() WHERE id=?",contradictory);
        assertThat(jobs.purgeResults(48)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_jobs WHERE id IN (?,?) AND result IS NOT NULL",Integer.class,active,contradictory)).isEqualTo(2);
    }

    @Test void aLiveCandidateIsNotCascadeDeletedByTheShorterJobRowPolicy() {
        UUID retained=job("SUCCEEDED","now()-interval '8 days'",false);
        UUID employee=UUID.randomUUID(),actor=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,?,'清理回归','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'
                """,employee,"RE-"+employee);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES(?,?,?,'test-only',false,'active')",actor,employee,"retention-"+actor);
        jdbc.update("""
                INSERT INTO sales_quote_template_candidates(job_id,actor_user_id,source_name,fingerprint,workbook_bytes,mapping,features,expires_at)
                VALUES(?,?,'sanitized.xlsx',repeat('b',64),decode('01','hex'),'{}','[]',now()+interval '1 day')
                """,retained,actor);
        assertThat(jobs.deleteFinishedOlderThan(7)).isZero();
        assertThat(exists(retained)).isTrue();
        jdbc.update("UPDATE sales_quote_template_candidates SET expires_at=now()-interval '1 second' WHERE job_id=?",retained);
        assertThat(jobs.deleteFinishedOlderThan(7)).isEqualTo(1);
    }

    @Test void futureCompletionWithUsageCannotAuthorizeResultPurge() {
        UUID contradictory=job("SUCCEEDED","now()+interval '1 day'",true);
        jdbc.update("UPDATE ai_jobs SET used_at=now() WHERE id=?",contradictory);
        assertThat(jobs.purgeResults(48)).isZero();
        assertThat(jdbc.queryForObject("SELECT result IS NOT NULL FROM ai_jobs WHERE id=?",Boolean.class,contradictory)).isTrue();
    }

    private UUID job(String status, String finishedAtSql, boolean result) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO ai_jobs(id,kind,status,input_name,input_content_type,input_kind,input_size,input_sha256,
                    submitted_by_user,submitted_auth_version,created_at,finished_at,result)
                VALUES(?,'RETENTION_TEST',?,'test.csv','text/csv','CSV',0,repeat('a',64),?,0,
                    now()-interval '30 days',%s,CAST(? AS jsonb))
                """.formatted(finishedAtSql), id, status, UUID.randomUUID(), result ? "{\"source\":\"test\"}" : null);
        return id;
    }

    private boolean exists(UUID id) {
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM ai_jobs WHERE id=?)", Boolean.class, id));
    }
}
