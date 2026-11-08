package com.uten.imp.features.workbench.badge;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WorkbenchBadgeSources;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import org.hibernate.Session;
import org.hibernate.jdbc.ReturningWork;
import org.hibernate.jdbc.Work;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.slf4j.Logger;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.SimpleTransactionStatus;

import java.sql.Connection;
import java.sql.Savepoint;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Supplier;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class WorkbenchBadgeSourceFailureTest {
    private static final String WARNING = "工作台徽章来源 {} 本次未算出: {}";
    private static final String RECOVERY = "工作台徽章来源 {} 已恢复，前次原因: {}";
    private static final String SOURCE = "serverOperations";
    private static final String ENTRY = "serverUpdateAvailable";

    private final Logger log = mock(Logger.class);
    private final AtomicInteger sourceReads = new AtomicInteger();
    private final EntityManager entityManager = mock(EntityManager.class);
    private final Connection connection = mock(Connection.class);
    private Supplier<Map<String, Long>> outcome;
    private WorkbenchBadgeService service;

    @BeforeEach
    void setUp() throws Exception {
        Set<String> keys = Arrays.stream(WorkbenchBadgeCatalog.values())
                .flatMap(entry -> Stream.concat(entry.todoFacts().stream(), entry.inProgressFacts().stream()))
                .map(WorkbenchBadgeCatalog::sourceOf).collect(java.util.stream.Collectors.toSet());
        List<WorkbenchBadgeSources.Source> registered = keys.stream()
                .map(key -> new WorkbenchBadgeSources.Source(key, () -> {
                    if (!SOURCE.equals(key)) return Map.of("count", 7L);
                    sourceReads.incrementAndGet();
                    return outcome.get();
                })).toList();
        WorkbenchBadgeSources contributor = () -> registered;
        var transactions = mock(PlatformTransactionManager.class);
        when(transactions.getTransaction(any())).thenAnswer(call -> new SimpleTransactionStatus());
        var scopes = mock(WarehouseTaskScopePort.class);
        when(scopes.withQueryScopeCache(any())).thenAnswer(call -> ((WarehouseTaskScopePort.ReadQuery<?>) call.getArgument(0)).read());
        service = new WorkbenchBadgeService(List.of(contributor), transactions, scopes, com.uten.imp.testsupport.TaskAudienceTestSupport.direct());

        Session session = mock(Session.class);
        when(connection.setSavepoint()).thenReturn(mock(Savepoint.class));
        when(entityManager.unwrap(Session.class)).thenReturn(session);
        BadgeStatementBudgetStubs.accept(entityManager);
        when(session.doReturningWork(any())).thenAnswer(call ->
                ((ReturningWork<?>) call.getArgument(0)).execute(connection));
        doAnswer(call -> {
            ((Work) call.getArgument(0)).execute(connection);
            return null;
        }).when(session).doWork(any());
        ReflectionTestUtils.setField(service, "entityManager", entityManager);
        ReflectionTestUtils.setField(service, "sourceDiagnostics",
                new WorkbenchBadgeSourceDiagnostics(keys, () -> 0L, log));
    }

    @Test
    void everyFailedPollReadsAgainAndMarksOnlyItsOwnEntriesAndSourcesStale() {
        outcome = () -> { throw new ApiException(ErrorCode.SERVER_OPERATIONS_UNAVAILABLE, "secret-token"); };
        for (int poll = 0; poll < 3; poll++) {
            WorkbenchBadgeSummary summary = service.summary(Set.of(ENTRY, "productionSchedule"));
            assertThat(summary.staleSources()).containsExactly(SOURCE);
            assertThat(summary.staleEntries()).containsExactly(ENTRY);
            assertThat(summary.entries().get("productionSchedule").todo()).isEqualTo(7L);
            assertThat(summary.facts()).containsEntry("productionSchedule.count", 7L)
                    .doesNotContainKey("serverOperations.updates");
        }

        assertThat(sourceReads).hasValue(3);
        verify(entityManager, times(3)).clear();
        verify(log).warn(WARNING, SOURCE, ErrorCode.SERVER_OPERATIONS_UNAVAILABLE.name());
        verifyNoMoreInteractions(log);
    }

    @Test
    void accessDeniedAndUnrequestedSourceCannotAnnounceOrClearRecovery() {
        outcome = () -> { throw new ApiException(ErrorCode.SERVER_OPERATIONS_UNAVAILABLE); };
        service.summary(Set.of(ENTRY));

        for (RuntimeException denial : List.of(new AccessDeniedException("secret-denied"),
                new ApiException(ErrorCode.FORBIDDEN), new ApiException(ErrorCode.UNAUTHORIZED))) {
            outcome = () -> { throw denial; };
            WorkbenchBadgeSummary denied = service.summary(Set.of(ENTRY));
            assertThat(denied.entries()).doesNotContainKey(ENTRY);
            assertThat(denied.staleEntries()).isEmpty();
            assertThat(denied.staleSources()).isEmpty();
        }
        outcome = () -> Map.of("updates", 2L);
        service.summary(Set.of("productionSchedule"));
        service.summary(Set.of());
        assertThat(sourceReads).hasValue(4);
        outcome = () -> { throw new ApiException(ErrorCode.SERVER_OPERATIONS_UNAVAILABLE); };
        service.summary(Set.of(ENTRY));

        assertThat(sourceReads).hasValue(5);
        verify(log).warn(WARNING, SOURCE, ErrorCode.SERVER_OPERATIONS_UNAVAILABLE.name());
        verifyNoMoreInteractions(log);

        outcome = () -> Map.of("updates", 2L);
        WorkbenchBadgeSummary recovered = service.summary(Set.of(ENTRY));
        assertThat(recovered.staleEntries()).isEmpty();
        assertThat(recovered.staleSources()).isEmpty();
        assertThat(recovered.entries().get(ENTRY).todo()).isEqualTo(2L);
        assertThat(recovered.facts()).containsEntry("serverOperations.updates", 2L);
        verify(log).info(RECOVERY, SOURCE, ErrorCode.SERVER_OPERATIONS_UNAVAILABLE.name());
        verifyNoMoreInteractions(log);

        outcome = () -> { throw new ApiException(ErrorCode.SERVER_OPERATIONS_UNAVAILABLE); };
        assertThat(service.summary(Set.of(ENTRY)).staleSources()).containsExactly(SOURCE);
        verify(log, times(2)).warn(WARNING, SOURCE, ErrorCode.SERVER_OPERATIONS_UNAVAILABLE.name());
    }

    @Test
    void runtimeFailureLogsOnlyItsTypeAndEmptySuccessfulReadStillProvesRecovery() {
        outcome = () -> { throw new IllegalStateException("credential=secret-token, customer=private"); };
        service.summary(Set.of(ENTRY));
        service.summary(Set.of(ENTRY));
        outcome = () -> null;
        WorkbenchBadgeSummary recovered = service.summary(Set.of(ENTRY));

        assertThat(sourceReads).hasValue(3);
        assertThat(recovered.staleSources()).isEmpty();
        assertThat(recovered.entries().get(ENTRY).todo()).isZero();
        verify(log).warn(WARNING, SOURCE, IllegalStateException.class.getName());
        verify(log).info(RECOVERY, SOURCE, IllegalStateException.class.getName());
        verifyNoMoreInteractions(log);
    }

    @Test
    void failedSavepointReleaseDoesNotAnnounceRecoveryBeforeTheReadIsComplete() throws Exception {
        outcome = () -> { throw new ApiException(ErrorCode.SERVER_OPERATIONS_UNAVAILABLE); };
        service.summary(Set.of(ENTRY));
        outcome = () -> Map.of("updates", 2L);
        doThrow(new IllegalStateException("secret-connection-detail")).when(connection).releaseSavepoint(any());

        assertThat(service.summary(Set.of(ENTRY)).staleSources()).containsExactly(SOURCE);
        verify(log).warn(WARNING, SOURCE, ErrorCode.SERVER_OPERATIONS_UNAVAILABLE.name());
        verify(log).warn(WARNING, SOURCE, IllegalStateException.class.getName());
        verifyNoMoreInteractions(log);

        doNothing().when(connection).releaseSavepoint(any());
        assertThat(service.summary(Set.of(ENTRY)).staleSources()).isEmpty();
        verify(log).info(RECOVERY, SOURCE, IllegalStateException.class.getName());
        verifyNoMoreInteractions(log);
    }

    /**
     * P3(2026-11-07 读取性能根治): 超过本来源语句时限的慢来源被取消并进入既有 stale 路径,
     * 之后的来源照常在收紧后的时限内执行, 汇总返回后调用方自己的 statement_timeout 原样保留。
     * 慢来源用另一连接持有排他锁的表构造(语句阻塞直到被时限取消); 仅真库运行。
     */
    @org.junit.jupiter.api.Test
    @org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
    void slowSourceIsCancelledIntoStaleWhileLaterSourcesAndTheCallerTimeoutAreKept() throws Exception {
        try (var postgres = new org.testcontainers.postgresql.PostgreSQLContainer("postgres:16-alpine")) {
            postgres.start();
            var dataSource = new org.springframework.jdbc.datasource.DriverManagerDataSource(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
            var configuration = new org.hibernate.cfg.Configuration().setProperty("hibernate.hbm2ddl.auto", "none");
            configuration.getProperties().put("hibernate.connection.datasource", dataSource);
            var factory = configuration.buildSessionFactory();
            try {
                var transactions = new org.springframework.orm.jpa.JpaTransactionManager(factory);
                transactions.setDataSource(dataSource);
                transactions.setJpaDialect(new org.springframework.orm.jpa.vendor.HibernateJpaDialect());
                jakarta.persistence.EntityManager shared =
                        org.springframework.orm.jpa.SharedEntityManagerCreator.createSharedEntityManager(factory);
                var tx = new org.springframework.transaction.support.TransactionTemplate(transactions);
                tx.execute(status -> { // 建锁探针表(提交), 慢来源的查询被另一连接锁住。
                    shared.createNativeQuery("CREATE TABLE badge_timeout_probe(id integer)").executeUpdate();
                    return null;
                });
                java.sql.Connection blocker = dataSource.getConnection();
                blocker.setAutoCommit(false);
                // 锁随事务持有到回滚；语句本身用完即关，不留未关闭资源。
                try (var lockStatement = blocker.createStatement()) {
                    lockStatement.execute("LOCK TABLE badge_timeout_probe IN ACCESS EXCLUSIVE MODE");
                }
                try {
                    List<String> limitsSeenAfterSlow = new java.util.concurrent.CopyOnWriteArrayList<>();
                    Set<String> keys = Arrays.stream(WorkbenchBadgeCatalog.values())
                            .flatMap(entry -> Stream.concat(entry.todoFacts().stream(), entry.inProgressFacts().stream()))
                            .map(WorkbenchBadgeCatalog::sourceOf).collect(java.util.stream.Collectors.toSet());
                    List<com.uten.imp.application.port.WorkbenchBadgeSources.Source> registered = keys.stream()
                            .map(key -> new com.uten.imp.application.port.WorkbenchBadgeSources.Source(key, () -> {
                                if (SOURCE.equals(key)) {
                                    shared.createNativeQuery("SELECT count(*) FROM badge_timeout_probe").getSingleResult();
                                    return Map.of("updates", 9L);
                                }
                                if ("productionSchedule".equals(key)) {
                                    limitsSeenAfterSlow.add((String) shared.createNativeQuery(
                                            "SELECT current_setting('statement_timeout')").getSingleResult());
                                    return Map.of("count", 7L);
                                }
                                return Map.of("count", 1L);
                            })).toList();
                    var scopes = mock(WarehouseTaskScopePort.class);
                    when(scopes.withQueryScopeCache(any())).thenAnswer(call ->
                            ((WarehouseTaskScopePort.ReadQuery<?>) call.getArgument(0)).read());
                    var timed = new WorkbenchBadgeService(List.of(() -> registered), transactions, scopes,
                            com.uten.imp.testsupport.TaskAudienceTestSupport.direct());
                    ReflectionTestUtils.setField(timed, "entityManager", shared);
                    ReflectionTestUtils.setField(timed, "sourceStatementTimeoutMillis", 200L);

                    tx.execute(status -> {
                        shared.createNativeQuery("SET LOCAL statement_timeout TO '7s'").executeUpdate();
                        long started = System.nanoTime();
                        WorkbenchBadgeSummary summary = timed.summary(Set.of(ENTRY, "productionSchedule"));
                        long elapsedMillis = (System.nanoTime() - started) / 1_000_000;
                        assertThat(summary.staleSources()).containsExactly(SOURCE);
                        assertThat(summary.staleEntries()).containsExactly(ENTRY);
                        assertThat(summary.entries().get("productionSchedule").todo()).isEqualTo(7L);
                        assertThat(summary.facts()).containsEntry("productionSchedule.count", 7L)
                                .doesNotContainKey("serverOperations.updates");
                        assertThat(limitsSeenAfterSlow).containsExactly("200ms");
                        assertThat(elapsedMillis).as("the blocked source is cut at its 200ms limit").isLessThan(2_000L);
                        assertThat(shared.createNativeQuery("SELECT current_setting('statement_timeout')")
                                .getSingleResult()).isEqualTo("7s");
                        status.setRollbackOnly();
                        return null;
                    });
                    // 调用方时限比来源上限更严时不放宽。
                    tx.execute(status -> {
                        shared.createNativeQuery("SET LOCAL statement_timeout TO '150ms'").executeUpdate();
                        limitsSeenAfterSlow.clear();
                        timed.summary(Set.of("productionSchedule"));
                        assertThat(limitsSeenAfterSlow).containsExactly("150ms");
                        assertThat(shared.createNativeQuery("SELECT current_setting('statement_timeout')")
                                .getSingleResult()).isEqualTo("150ms");
                        status.setRollbackOnly();
                        return null;
                    });
                } finally {
                    blocker.rollback();
                    blocker.close();
                    tx.execute(status -> {
                        shared.createNativeQuery("DROP TABLE badge_timeout_probe").executeUpdate();
                        return null;
                    });
                }
            } finally {
                factory.close();
            }
        }
    }
}
