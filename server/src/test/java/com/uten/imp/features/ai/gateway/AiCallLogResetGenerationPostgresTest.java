package com.uten.imp.features.ai.gateway;

import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.features.admin.systemtest.BusinessDataResetDrainGate;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.ai.client.AiProtocolClient;
import com.uten.imp.features.ai.provider.*;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.Connection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/** Uses real forward migrations and the real explicit test-reset transaction. No external AI service. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AiCallLogResetGenerationPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static DriverManagerDataSource dataSource;
    static JdbcTemplate jdbc;
    BusinessDataResetDrainGate gate;
    AiProtocolClient client;
    AiProviderRuntime runtime;
    AiGateway gateway;
    CountDownLatch started;
    CountDownLatch release;
    ExecutorService executor;

    @BeforeAll
    static void open() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("ai_log_reset_generation");
        dataSource = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        // This regression must travel with V782; an absent column is not an old-schema fallback.
        assertThat(jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1", Long.class))
                .isNotNegative();
    }

    @AfterAll
    static void close() throws Exception {
        if (database != null) database.close();
    }

    @BeforeEach
    void setup() {
        jdbc.queryForList("SELECT * FROM business_data_reset()");
        gate = new BusinessDataResetDrainGate();
        var logs = new AiCallLogService(new NamedParameterJdbcTemplate(jdbc), new DataSourceTransactionManager(dataSource), gate);
        var providers = mock(AiProviderService.class);
        runtime = mock(AiProviderRuntime.class);
        when(runtime.protocol()).thenReturn(AiProtocol.OPENAI_CHAT);
        when(runtime.name()).thenReturn("reset-generation-fixture");
        when(runtime.model()).thenReturn("fixture");
        when(runtime.maxOutputTokens()).thenReturn(1024);
        when(runtime.supportsVision()).thenReturn(true);
        var resolution = new AiProviderService.Resolution(runtime, runtime.name(), runtime.model(), true, null);
        when(providers.resolveDefault()).thenReturn(resolution);
        client = mock(AiProtocolClient.class);
        when(client.protocol()).thenReturn(AiProtocol.OPENAI_CHAT);
        when(client.chat(any(), any())).thenReturn(response());
        var current = mock(SecurityContextCurrentUser.class);
        when(current.id()).thenReturn(Optional.empty());
        var properties = new AiProperties();
        properties.setDailyTokenBudget(0);
        gateway = new AiGateway(providers, List.of(client), logs, properties, current);
        started = new CountDownLatch(1);
        release = new CountDownLatch(1);
        executor = Executors.newSingleThreadExecutor();
    }

    @AfterEach
    void stop() throws Exception {
        if (release != null) release.countDown();
        if (executor != null) {
            executor.shutdownNow();
            assertThat(executor.awaitTermination(10, TimeUnit.SECONDS)).isTrue();
        }
    }

    @Test
    void lateLogicalCallCannotReinsertItsClearedJobLog() throws Exception {
        UUID oldJob = UUID.randomUUID();
        blockNetwork();
        Future<?> call = executor.submit(() -> gateway.completeJson(request(oldJob)));
        awaitStarted();
        long generation = generation();
        commitReset();
        assertThat(generation()).isEqualTo(generation + 1);
        assertThat(gate.blockingNewRequests()).isFalse();
        release.countDown();
        call.get(10, TimeUnit.SECONDS);
        assertThat(logs()).as("the old call ended after the clear, but belongs to the old dataset").isZero();
    }

    @Test
    void writerWaitingForResetTableLockChecksTheGenerationAfterTheResetCommits() throws Exception {
        blockNetwork();
        Future<?> call = executor.submit(() -> gateway.completeJson(request(null)));
        awaitStarted();
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try (var statement = connection.createStatement()) {
                statement.executeQuery("SELECT * FROM business_data_reset()").close();
            }
            // Model a reset in a different process: this local gate is already IDLE.
            release.countDown();
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
            while (System.nanoTime() < deadline && waitingLogLocks() == 0) Thread.sleep(10);
            assertThat(waitingLogLocks()).as("the old result really waits behind the reset's table lock").isPositive();
            connection.commit();
        }
        call.get(10, TimeUnit.SECONDS);
        assertThat(logs()).isZero();
    }

    @Test
    void aNewCallWithoutAJobIsRecordedAndPermissionEpochChangesDoNotEraseItsCost() throws Exception {
        gateway.completeJson(request(null));
        assertThat(logs()).isEqualTo(1);
        long generation = generation();
        blockNetwork();
        Future<?> call = executor.submit(() -> gateway.completeJson(request(null)));
        awaitStarted();
        jdbc.update("UPDATE authorization_state SET epoch=epoch+1 WHERE singleton_id=1");
        assertThat(generation()).isEqualTo(generation);
        release.countDown();
        call.get(10, TimeUnit.SECONDS);
        assertThat(logs()).as("ordinary permission refresh is not a test-data clear").isEqualTo(2);
    }

    @Test
    void rolledBackResetDoesNotInvalidateAnExistingLogicalCall() throws Exception {
        blockNetwork();
        Future<?> call = executor.submit(() -> gateway.completeJson(request(null)));
        awaitStarted();
        long generation = generation();
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try (var statement = connection.createStatement()) {
                statement.executeQuery("SELECT * FROM business_data_reset()").close();
            }
            connection.rollback();
        }
        assertThat(generation()).isEqualTo(generation);
        release.countDown();
        call.get(10, TimeUnit.SECONDS);
        assertThat(logs()).isEqualTo(1);
    }

    @Test
    void connectionProbeDoesNotReuseItsCallersOldRepeatableReadSnapshotForLogInsertion() throws Exception {
        blockNetwork();
        var outer = new TransactionTemplate(new DataSourceTransactionManager(dataSource));
        outer.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
        Future<?> call = executor.submit(() -> outer.execute(status -> {
            generation(); // Establish an old caller snapshot before the reset.
            return gateway.probeChat(runtime, new AiProtocolClient.ChatRequest("test", List.of(), null, null, 10), "RESET_PROBE");
        }));
        awaitStarted();
        commitReset();
        release.countDown();
        call.get(10, TimeUnit.SECONDS);
        assertThat(logs()).isZero();
    }

    private void blockNetwork() {
        when(client.chat(any(), any())).thenAnswer(invocation -> {
            started.countDown();
            assertThat(release.await(30, TimeUnit.SECONDS)).as("test release, never a timing-based network guess").isTrue();
            return response();
        });
    }

    private void awaitStarted() throws InterruptedException {
        assertThat(started.await(10, TimeUnit.SECONDS)).isTrue();
    }

    private void commitReset() throws Exception {
        assertThat(gate.beginDrain(5_000)).isTrue();
        try { jdbc.queryForList("SELECT * FROM business_data_reset()"); }
        finally { gate.endReset(); }
    }

    private static long generation() {
        return jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1", Long.class);
    }

    private static long logs() { return jdbc.queryForObject("SELECT count(*) FROM ai_call_logs", Long.class); }

    private static long waitingLogLocks() {
        return jdbc.queryForObject("SELECT count(*) FROM pg_locks WHERE relation='public.ai_call_logs'::regclass AND NOT granted", Long.class);
    }

    private static AiProtocolClient.ChatResponse response() {
        return new AiProtocolClient.ChatResponse("{\"ok\":true}", 7, 3, 200, false, 1);
    }

    private static AiCompletionPort.AiCompletionRequest request(UUID job) {
        return new AiCompletionPort.AiCompletionRequest("RESET_FENCE", "test", List.of(new AiCompletionPort.AiText("test", false)), null, null, 10, job);
    }
}
