package com.uten.imp.features.notice;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Executes the production native query and forward repair on entity-owned PostgreSQL tables. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class NoticeAcknowledgmentReadPostgresTest {
    private static final PostgreSQLContainer DB = new PostgreSQLContainer("postgres:16-alpine");
    private static final Instant EARLIER = Instant.parse("2026-11-01T10:00:00Z");
    private static SessionFactory factory;
    private static JdbcTemplate jdbc;
    private static NamedParameterJdbcTemplate named;
    private static TransactionTemplate transaction;
    private static String acknowledgeSql;

    @BeforeAll
    static void start() throws Exception {
        DB.start();
        var source = new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        var configuration = new Configuration()
                .addAnnotatedClass(NoticeAcknowledgment.class)
                .addAnnotatedClass(NoticeUserState.class)
                .setProperty("hibernate.hbm2ddl.auto", "create");
        configuration.getProperties().put("hibernate.connection.datasource", source);
        factory = configuration.buildSessionFactory();
        jdbc = new JdbcTemplate(source);
        named = new NamedParameterJdbcTemplate(source);
        transaction = new TransactionTemplate(new DataSourceTransactionManager(source));
        acknowledgeSql = NoticeAcknowledgmentRepository.class
                .getMethod("acknowledgeAndMarkRead", UUID.class, UUID.class)
                .getAnnotation(Query.class).value();
    }

    @AfterAll
    static void stop() {
        if (factory != null) factory.close();
        DB.stop();
    }

    @BeforeEach
    void clear() {
        jdbc.execute("TRUNCATE notice_acknowledgments, notice_user_states");
    }

    @Test
    void confirmingReceiptCreatesReadStateAndPreservesExistingLifecycleFacts() {
        UUID notice = UUID.randomUUID(), user = UUID.randomUUID(), other = UUID.randomUUID();
        try (var entityManager = factory.createEntityManager()) {
            var repository = new JpaRepositoryFactory(entityManager).getRepository(NoticeAcknowledgmentRepository.class);
            entityManager.getTransaction().begin();
            repository.acknowledgeAndMarkRead(notice, user);
            entityManager.getTransaction().commit();
        }
        assertThat(readAt(notice, user)).isNotNull();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notice_acknowledgments", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT popup_acknowledged_at IS NULL AND task_completed_at IS NULL FROM notice_user_states", Boolean.class)).isTrue();

        jdbc.update("UPDATE notice_user_states SET read_at=?, popup_acknowledged_at=?, snoozed_until=?, task_completed_at=?",
                java.sql.Timestamp.from(EARLIER), java.sql.Timestamp.from(EARLIER),
                java.sql.Timestamp.from(EARLIER.plusSeconds(900)), java.sql.Timestamp.from(EARLIER));
        acknowledge(notice, user);
        assertThat(readAt(notice, user)).isEqualTo(EARLIER);
        assertThat(jdbc.queryForObject("SELECT popup_acknowledged_at FROM notice_user_states", java.sql.Timestamp.class).toInstant()).isEqualTo(EARLIER);
        assertThat(jdbc.queryForObject("SELECT snoozed_until FROM notice_user_states", java.sql.Timestamp.class).toInstant()).isEqualTo(EARLIER.plusSeconds(900));
        assertThat(jdbc.queryForObject("SELECT task_completed_at FROM notice_user_states", java.sql.Timestamp.class).toInstant()).isEqualTo(EARLIER);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notice_user_states WHERE user_id=?", Integer.class, other)).isZero();
    }

    @Test
    void concurrentRepeatedReceiptKeepsOneAckAndOneReadState() throws Exception {
        UUID notice = UUID.randomUUID(), user = UUID.randomUUID();
        var start = new CountDownLatch(1);
        try (var pool = Executors.newFixedThreadPool(8)) {
            var futures = java.util.stream.IntStream.range(0, 8).mapToObj(i -> pool.submit(() -> {
                start.await();
                acknowledge(notice, user);
                return true;
            })).toList();
            start.countDown();
            for (var future : futures) assertThat(future.get(20, TimeUnit.SECONDS)).isTrue();
        }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notice_acknowledgments", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notice_user_states WHERE read_at IS NOT NULL", Integer.class)).isEqualTo(1);
    }

    @Test
    void rollbackCannotLeaveAReceiptWithoutItsReadState() {
        UUID notice = UUID.randomUUID(), user = UUID.randomUUID();
        assertThatThrownBy(() -> transaction.executeWithoutResult(status -> {
            update(notice, user);
            throw new IllegalStateException("interrupted transaction");
        })).isInstanceOf(IllegalStateException.class);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notice_acknowledgments", Integer.class)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notice_user_states", Integer.class)).isZero();
    }

    @Test
    void historicalRepairIsRecipientScopedIdempotentAndDoesNotReviveDeletedOrPopupOnlyRows() throws Exception {
        UUID notice = UUID.randomUUID(), unread = UUID.randomUUID(), missing = UUID.randomUUID();
        UUID read = UUID.randomUUID(), deleted = UUID.randomUUID(), popupOnly = UUID.randomUUID();
        for (UUID user : java.util.List.of(unread, missing, read, deleted)) {
            jdbc.update("INSERT INTO notice_acknowledgments(notice_id,user_id,acked_at) VALUES (?,?,?)",
                    notice, user, java.sql.Timestamp.from(EARLIER));
        }
        jdbc.update("INSERT INTO notice_user_states(notice_id,user_id,snoozed_until) VALUES (?,?,?)", notice, unread, java.sql.Timestamp.from(EARLIER.plusSeconds(900)));
        jdbc.update("INSERT INTO notice_user_states(notice_id,user_id,read_at) VALUES (?,?,?)", notice, read, java.sql.Timestamp.from(EARLIER.minusSeconds(900)));
        jdbc.update("INSERT INTO notice_user_states(notice_id,user_id,deleted_at) VALUES (?,?,?)", notice, deleted, java.sql.Timestamp.from(EARLIER));
        jdbc.update("INSERT INTO notice_user_states(notice_id,user_id,popup_acknowledged_at) VALUES (?,?,?)", notice, popupOnly, java.sql.Timestamp.from(EARLIER));
        String migration = Files.readString(Path.of("src/main/resources/db/migration/V1023__notice_acknowledgment_marks_read.sql"));
        jdbc.execute(migration);
        jdbc.execute(migration);
        assertThat(readAt(notice, unread)).isEqualTo(EARLIER);
        assertThat(readAt(notice, missing)).isEqualTo(EARLIER);
        assertThat(readAt(notice, read)).isEqualTo(EARLIER.minusSeconds(900));
        assertThat(readAt(notice, deleted)).isNull();
        assertThat(readAt(notice, popupOnly)).isNull();
        assertThat(jdbc.queryForObject("SELECT snoozed_until FROM notice_user_states WHERE user_id=?", java.sql.Timestamp.class, unread).toInstant()).isEqualTo(EARLIER.plusSeconds(900));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notice_user_states WHERE task_completed_at IS NOT NULL", Integer.class)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notice_user_states WHERE popup_acknowledged_at IS NOT NULL", Integer.class)).isEqualTo(1);
    }

    private void acknowledge(UUID notice, UUID user) {
        transaction.executeWithoutResult(status -> update(notice, user));
    }

    private void update(UUID notice, UUID user) {
        named.update(acknowledgeSql, Map.of("noticeId", notice, "userId", user));
    }

    private Instant readAt(UUID notice, UUID user) {
        var timestamp = jdbc.queryForObject("SELECT read_at FROM notice_user_states WHERE notice_id=? AND user_id=?",
                java.sql.Timestamp.class, notice, user);
        return timestamp == null ? null : timestamp.toInstant();
    }
}
