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
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.annotation.EnableTransactionManagement;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import javax.sql.DataSource;

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
import static org.mockito.Mockito.doAnswer;
import static org.junit.jupiter.api.Assertions.assertNotEquals;

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
        jdbc.execute("CREATE TABLE outbox_wake_test_deliveries(aggregate_id UUID PRIMARY KEY)");
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @BeforeEach
    void setUp() {
        jdbc.update("DELETE FROM business_outbox");
        jdbc.update("DELETE FROM outbox_wake_test_deliveries");
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

    @Test
    void springCommitEnqueuesOnlyAfterCommitAndOneDispatchDrainsMoreThanTwenty() {
        var worker = new ManualOutboxExecutor();
        recordSuccessfulDeliveries();
        try (var context = springContext(worker)) {
            var springPublisher = context.getBean(BusinessOutboxPublisher.class);
            transactions.executeWithoutResult(status -> {
                for (int i = 0; i < 61; i++) springPublisher.publishOnce(
                        "TEST_EVENT", "TEST", UUID.randomUUID(), Map.of(), "committed-"+i);
                assertEquals(0, worker.queued(), "uncommitted events must not enqueue any worker");
                assertEquals(0L, deliveries());
            });
            assertEquals(1, worker.queued(), "all commit markers coalesce into one bounded dispatch");
            assertEquals(0L, deliveries(), "the request thread only enqueues; it does not deliver inline");
            worker.runOne();
            assertEquals(61L, deliveries());
            assertEquals(61L, jdbc.queryForObject("SELECT COUNT(*) FROM business_outbox WHERE status=1", Long.class));
            assertEquals(1, worker.submitted(), "no 2-second scheduled ticks were needed for later batches");
        }
    }

    @Test
    void springRollbackProducesNeitherAQueueHintNorADurableEvent() {
        var worker = new ManualOutboxExecutor();
        try (var context = springContext(worker)) {
            var springPublisher = context.getBean(BusinessOutboxPublisher.class);
            transactions.executeWithoutResult(status -> {
                springPublisher.publishOnce("TEST_EVENT", "TEST", UUID.randomUUID(), Map.of(), "spring-rollback");
                assertEquals(0, worker.queued());
                status.setRollbackOnly();
            });
            assertEquals(0, worker.submitted());
            assertEquals(0L, countEvents());
            context.publishEvent(new BusinessOutboxReady(UUID.randomUUID()));
            assertEquals(0, worker.submitted(), "a marker without a transaction has no AFTER_COMMIT delivery");
        }
    }

    @Test
    void committedDuplicateDoesNotWakeOrDeliverAgain() {
        var worker = new ManualOutboxExecutor();
        recordSuccessfulDeliveries();
        try (var context = springContext(worker)) {
            var springPublisher = context.getBean(BusinessOutboxPublisher.class);
            UUID aggregate = UUID.randomUUID();
            UUID first = springPublisher.publishOnce("TEST_EVENT", "TEST", aggregate, Map.of(), "committed-dedupe");
            worker.runOne();
            UUID duplicate = springPublisher.publishOnce("TEST_EVENT", "TEST", aggregate, Map.of(), "committed-dedupe");
            assertEquals(first, duplicate);
            assertEquals(1, worker.submitted());
            assertEquals(0, worker.queued());
            assertEquals(1L, deliveries());
        }
    }

    @Test
    void failedDeliveryRollsBackItsWritesAndKeepsDurableBackoffAcrossWakeups() {
        var worker = new ManualOutboxExecutor();
        var failing = new AtomicBoolean(true);
        var calls = new AtomicInteger();
        doAnswer(call -> {
            calls.incrementAndGet();
            jdbc.update("INSERT INTO outbox_wake_test_deliveries VALUES (?)", call.getArgument(1, UUID.class));
            if (failing.get()) throw new IllegalStateException("temporary delivery failure");
            return null;
        }).when(chainNotice).deliverOutboxEvent(anyString(), any(), any());
        try (var context = springContext(worker)) {
            var springPublisher = context.getBean(BusinessOutboxPublisher.class);
            var scheduler = context.getBean(BusinessOutboxScheduler.class);
            UUID id = springPublisher.publishOnce("TEST_EVENT", "TEST", UUID.randomUUID(), Map.of(), "wake-retry");
            worker.runOne();
            assertEquals(0L, deliveries(), "failed transaction must not leave a partial notice");
            assertEquals(0, eventStatus("wake-retry"));
            assertEquals(1, jdbc.queryForObject("SELECT attempts FROM business_outbox WHERE id=?", Integer.class, id));
            assertTrue(Boolean.TRUE.equals(jdbc.queryForObject(
                    "SELECT available_at > created_at + interval '1 second' FROM business_outbox WHERE id=?", Boolean.class, id)));
            // Freeze future eligibility for a deterministic clock-independent probe.
            jdbc.update("UPDATE business_outbox SET available_at=now()+interval '1 minute' WHERE id=?", id);
            for (int i = 0; i < 50; i++) scheduler.drain();
            worker.runOne();
            assertEquals(1, calls.get(), "waking cannot bypass available_at");
            failing.set(false);
            jdbc.update("UPDATE business_outbox SET available_at=now() WHERE id=?", id);
            scheduler.drain(); worker.runOne();
            assertEquals(1, eventStatus("wake-retry"));
            assertEquals(1L, deliveries());
            assertEquals(2, calls.get());
        }
    }

    @Test
    void shutdownCanDiscardOnlyTheHintAndANewWorkerRecoversTheDurableRow() {
        var abandoned = new ManualOutboxExecutor();
        UUID id;
        recordSuccessfulDeliveries();
        try (var context = springContext(abandoned)) {
            id = context.getBean(BusinessOutboxPublisher.class).publishOnce(
                    "TEST_EVENT", "TEST", UUID.randomUUID(), Map.of(), "shutdown-pending");
            assertEquals(1, abandoned.queued());
            context.getBean(BusinessOutboxScheduler.class).close();
            context.getBean(BusinessOutboxPublisher.class).publishOnce(
                    "TEST_EVENT", "TEST", UUID.randomUUID(), Map.of(), "shutdown-committed-late");
            assertEquals(1, abandoned.submitted(), "a transaction committed after worker shutdown must remain durable without another dispatch");
        }
        assertEquals(0, eventStatus("shutdown-pending"));
        assertEquals(0L, deliveries());
        var restarted = new ManualOutboxExecutor();
        try (var context = springContext(restarted)) {
            context.getBean(BusinessOutboxScheduler.class).drain();
            restarted.runOne();
            assertEquals(id, jdbc.queryForObject("SELECT id FROM business_outbox WHERE dedupe_key='shutdown-pending'", UUID.class));
            assertEquals(2L, deliveries());
            assertEquals(1, eventStatus("shutdown-committed-late"));
        }
    }

    @Test
    void committedDeliveryUsesAnIndependentWorkerTransactionAndThread() throws Exception {
        var committed = new CountDownLatch(1);
        var deliveryThread = new AtomicReference<Thread>();
        doAnswer(call -> {
            assertTrue(TransactionSynchronizationManager.isActualTransactionActive());
            deliveryThread.set(Thread.currentThread());
            jdbc.update("INSERT INTO outbox_wake_test_deliveries VALUES (?)", call.getArgument(1, UUID.class));
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override public void afterCommit() { committed.countDown(); }
            });
            return null;
        }).when(chainNotice).deliverOutboxEvent(anyString(), any(), any());
        try (var context = springContext(null)) {
            var springPublisher = context.getBean(BusinessOutboxPublisher.class);
            transactions.executeWithoutResult(status -> {
                springPublisher.publishOnce("TEST_EVENT", "TEST", UUID.randomUUID(), Map.of(), "real-worker");
                assertEquals(1L, committed.getCount());
                assertEquals(0L, deliveries());
            });
            assertTrue(committed.await(5, TimeUnit.SECONDS));
            assertNotEquals(Thread.currentThread(), deliveryThread.get());
            assertEquals(1L, deliveries());
            assertEquals(1, eventStatus("real-worker"));
        }
    }

    private void recordSuccessfulDeliveries() {
        doAnswer(call -> {
            jdbc.update("INSERT INTO outbox_wake_test_deliveries VALUES (?)", call.getArgument(1, UUID.class));
            return null;
        }).when(chainNotice).deliverOutboxEvent(anyString(), any(), any());
    }

    private long deliveries() {
        return jdbc.queryForObject("SELECT COUNT(*) FROM outbox_wake_test_deliveries", Long.class);
    }

    private AnnotationConfigApplicationContext springContext(ExecutorService worker) {
        var context = new AnnotationConfigApplicationContext();
        context.register(Transactions.class);
        context.registerBean(DataSource.class, () -> jdbc.getDataSource());
        context.registerBean(JdbcTemplate.class, () -> jdbc);
        context.registerBean(ObjectMapper.class, () -> new ObjectMapper());
        context.registerBean(SecurityContextCurrentUser.class, () -> {
            var currentUser = mock(SecurityContextCurrentUser.class);
            when(currentUser.get()).thenReturn(Optional.empty());
            return currentUser;
        });
        context.registerBean(ChainNoticeService.class, () -> chainNotice);
        context.registerBean(BusinessOutboxPublisher.class);
        context.registerBean(BusinessOutboxProcessor.class, () -> new BusinessOutboxProcessor(
                jdbc, context.getBean(ObjectMapper.class), chainNotice));
        context.registerBean(BusinessOutboxFailureRecorder.class, () -> new BusinessOutboxFailureRecorder(jdbc));
        context.registerBean(BusinessOutboxScheduler.class, () -> worker == null
                ? new BusinessOutboxScheduler(context.getBean(BusinessOutboxProcessor.class), context.getBean(BusinessOutboxFailureRecorder.class))
                : new BusinessOutboxScheduler(context.getBean(BusinessOutboxProcessor.class), context.getBean(BusinessOutboxFailureRecorder.class),
                        OutboxWarnThrottler.withDefaults(), worker));
        context.refresh();
        return context;
    }

    @Configuration(proxyBeanMethods = false)
    @EnableTransactionManagement(proxyTargetClass = true)
    static class Transactions {
        @Bean PlatformTransactionManager transactionManager(DataSource dataSource) {
            return new JdbcTransactionManager(dataSource);
        }
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
