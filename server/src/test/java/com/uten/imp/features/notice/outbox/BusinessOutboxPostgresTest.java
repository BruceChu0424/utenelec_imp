package com.uten.imp.features.notice.outbox;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.reset;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** Real PostgreSQL evidence for transactional append, retry, and deduplication. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class BusinessOutboxPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static JdbcTemplate jdbc;
    private static TransactionTemplate transactions;

    private BusinessOutboxPublisher publisher;
    private BusinessOutboxProcessor processor;
    private ChainNoticeService chainNotice;

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
        var dataSource = new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        transactions = new TransactionTemplate(new JdbcTransactionManager(dataSource));
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @BeforeEach
    void setUp() {
        jdbc.update("DELETE FROM business_outbox");
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.empty());
        publisher = new BusinessOutboxPublisher(jdbc, new ObjectMapper(), currentUser);
        chainNotice = mock(ChainNoticeService.class);
        processor = new BusinessOutboxProcessor(jdbc, new ObjectMapper(), chainNotice);
    }

    @Test
    void eventAppendRollsBackWithItsBusinessTransaction() {
        assertThrows(IntentionalRollback.class, () ->
                transactions.executeWithoutResult(status -> {
                    publisher.publishOnce(
                            "TEST_EVENT",
                            "TEST",
                            UUID.randomUUID(),
                            Map.of("value", 1),
                            "rollback-key");
                    throw new IntentionalRollback();
                }));

        assertEquals(0L, countEvents());
    }

    @Test
    void failedDeliveryRollsBackThenTheSameEventCanBeRetried() {
        UUID aggregateId = UUID.randomUUID();
        transactions.executeWithoutResult(status -> publisher.publishOnce(
                "TEST_EVENT",
                "TEST",
                aggregateId,
                Map.of("value", 1),
                "retry-key"));

        doThrow(new IllegalStateException("temporary"))
                .when(chainNotice)
                .deliverOutboxEvent(anyString(), any(), any());
        assertThrows(OutboxDeliveryException.class, () ->
                transactions.executeWithoutResult(status -> processor.processNext()));
        assertEquals(0, eventStatus("retry-key"));

        reset(chainNotice);
        assertTrue(Boolean.TRUE.equals(
                transactions.execute(status -> processor.processNext())));
        assertEquals(1, eventStatus("retry-key"));
        verify(chainNotice).deliverOutboxEvent(
                anyString(), any(UUID.class), any());
    }

    @Test
    void deterministicDedupeKeyCreatesOneEvent() {
        UUID aggregateId = UUID.randomUUID();
        UUID first = transactions.execute(status -> publisher.publishOnce(
                "TEST_EVENT",
                "TEST",
                aggregateId,
                Map.of(),
                "same-key"));
        UUID second = transactions.execute(status -> publisher.publishOnce(
                "TEST_EVENT",
                "TEST",
                aggregateId,
                Map.of(),
                "same-key"));

        assertEquals(first, second);
        assertEquals(1L, countEvents());
    }

    @Test
    void deterministicDedupeKeyRejectsDifferentPayloadOrIdentity() {
        UUID aggregateId = UUID.randomUUID();
        transactions.executeWithoutResult(status -> publisher.publishOnce(
                "TEST_EVENT",
                "TEST",
                aggregateId,
                Map.of("value", 1),
                "guarded-key"));

        assertThrows(ApiException.class, () ->
                transactions.executeWithoutResult(status -> publisher.publishOnce(
                        "TEST_EVENT",
                        "TEST",
                        aggregateId,
                        Map.of("value", 2),
                        "guarded-key")));
        assertThrows(ApiException.class, () ->
                transactions.executeWithoutResult(status -> publisher.publishOnce(
                        "OTHER_EVENT",
                        "TEST",
                        aggregateId,
                        Map.of("value", 1),
                        "guarded-key")));
        assertEquals(1L, countEvents());
    }

    private long countEvents() {
        Long value = jdbc.queryForObject(
                "SELECT COUNT(*) FROM business_outbox",
                Long.class);
        return value == null ? 0 : value;
    }

    private int eventStatus(String key) {
        Integer value = jdbc.queryForObject(
                "SELECT status FROM business_outbox WHERE dedupe_key = ?",
                Integer.class,
                key);
        return value == null ? -1 : value;
    }

    private static final class IntentionalRollback extends RuntimeException {
    }
}
