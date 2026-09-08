package com.uten.imp.features.common.taskclaim;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Properties;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.*;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/** Real row-lock races; database wait state establishes operation ordering. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class TaskClaimMutationConcurrencyPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final List<String> TYPES = List.of("EXPENSE_APPROVE", "SALES_ORDER_FINANCE_CONFIRM");
    private static EntityManagerFactory emf;
    private static EntityManager em;
    private static JdbcTemplate jdbc;
    private static TransactionTemplate transactions;
    private static TaskClaimRepository repository;
    private final UUID owner = UUID.randomUUID();
    private final UUID manager = UUID.randomUUID();
    private TaskClaimService service;
    private AuditService audit;

    @BeforeAll
    static void start() {
        DB.start();
        var dataSource = new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        var factory = new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(dataSource);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setPackagesToScan("com.uten.imp.features.common.taskclaim");
        var properties = new Properties();
        properties.setProperty("hibernate.hbm2ddl.auto", "create-drop");
        properties.setProperty("hibernate.jdbc.time_zone", "UTC");
        factory.setJpaProperties(properties);
        factory.afterPropertiesSet();
        emf = factory.getObject();
        em = SharedEntityManagerCreator.createSharedEntityManager(emf);
        transactions = new TransactionTemplate(new JpaTransactionManager(emf));
        transactions.setTimeout(15);
        repository = new JpaRepositoryFactory(em).getRepository(TaskClaimRepository.class);
        jdbc.execute("CREATE UNIQUE INDEX uq_task_claim_active ON task_claims(target_type,target_key) WHERE released_at IS NULL");
        jdbc.execute("""
                CREATE TABLE sales_orders(id uuid PRIMARY KEY, status smallint NOT NULL DEFAULT 1,
                  is_deleted boolean NOT NULL DEFAULT FALSE, finance_confirmed boolean NOT NULL DEFAULT FALSE,
                  finance_rejected boolean NOT NULL DEFAULT FALSE, is_stopped boolean NOT NULL DEFAULT FALSE,
                  is_closed boolean NOT NULL DEFAULT FALSE,finance_review_revision bigint NOT NULL DEFAULT 0)
                """);
    }

    @AfterAll
    static void stop() {
        if (emf != null) emf.close();
        DB.stop();
    }

    @BeforeEach
    void setUp() {
        var names = mock(EmployeeNameResolver.class);
        when(names.nameOf(any())).thenReturn("Reviewer");
        audit = mock(AuditService.class);
        var salesReviewers = mock(com.uten.imp.application.port.SalesOrderFinanceReviewerEligibilityPort.class);
        when(salesReviewers.isEligible(any())).thenReturn(true);
        service = new TaskClaimService(repository,names,new SecurityContextCurrentUser(),audit,
                List.of(new com.uten.imp.features.sales.order.SalesFinanceClaimTargetLocks(em)),
                mock(com.uten.imp.application.port.FinanceReviewerEligibilityPort.class), salesReviewers);
    }

    @Test
    void manualReleaseCannotBeResurrectedByAWaitingHeartbeat() throws Exception {
        for (String type : TYPES) releaseThenHeartbeat(type, false);
    }

    @Test
    void forceReleaseCannotBeResurrectedByAWaitingHeartbeat() throws Exception {
        for (String type : TYPES) releaseThenHeartbeat(type, true);
    }

    private void releaseThenHeartbeat(String type, boolean force) throws Exception {
        Fixture task = seed(type, 1);
        Object leaseBefore = jdbc.queryForObject("SELECT lease_until FROM task_claims WHERE id=?", Object.class, task.id);
        try (var workers = Executors.newFixedThreadPool(2); Connection blocker = lockClaim(task)) {
            Future<?> release = workers.submit(() -> as("release", force ? manager : owner, () -> {
                if (force) service.forceRelease(task.type, task.key); else service.release(task.type, task.key);
                return null;
            }));
            assertLockWaiting(release, "release");
            Future<?> heartbeat = workers.submit(() -> as("heartbeat", owner, () -> service.heartbeat(task.type, task.key)));
            assertLockWaiting(heartbeat, "heartbeat");
            blocker.commit();
            release.get(10, TimeUnit.SECONDS);
            assertConflict(heartbeat);
        }
        assertThat(activeCount(task)).isZero();
        assertThat(jdbc.queryForObject("SELECT lease_until FROM task_claims WHERE id=?", Object.class, task.id)).isEqualTo(leaseBefore);
    }

    @Test
    void takeoverWinsWithoutDeadlockAndOldHeartbeatCannotRestoreThePreviousClaim() throws Exception {
        for (String type : TYPES) {
            Fixture task = seed(type, 1);
            try (var workers = Executors.newFixedThreadPool(2); Connection blocker = lockClaim(task)) {
                Future<?> takeover = workers.submit(() -> as("takeover", manager, () -> service.takeover(task.type, task.key)));
                assertLockWaiting(takeover, "takeover");
                Future<?> heartbeat = workers.submit(() -> as("heartbeat", owner, () -> service.heartbeat(task.type, task.key)));
                assertLockWaiting(heartbeat, "heartbeat");
                blocker.commit();
                takeover.get(10, TimeUnit.SECONDS);
                assertConflict(heartbeat);
            }
            assertThat(activeCount(task)).isEqualTo(1);
            assertThat(jdbc.queryForObject("SELECT claimed_by FROM task_claims WHERE target_type=? AND target_key=? AND released_at IS NULL",
                    UUID.class, task.type, task.key)).isEqualTo(manager);
            assertThat(jdbc.queryForObject("SELECT release_reason FROM task_claims WHERE id=?", String.class, task.id)).isEqualTo("takeover");
        }
    }

    @Test
    void releaseAfterAWinningHeartbeatStillLeavesTheClaimReleased() throws Exception {
        for (String type : TYPES) {
            Fixture task = seed(type, 1);
            try (var workers = Executors.newFixedThreadPool(2); Connection blocker = lockClaim(task)) {
                Future<?> heartbeat = workers.submit(() -> as("heartbeat", owner, () -> service.heartbeat(task.type, task.key)));
                assertLockWaiting(heartbeat, "heartbeat");
                Future<?> release = workers.submit(() -> as("release", manager, () -> {
                    service.forceRelease(task.type, task.key); return null;
                }));
                assertLockWaiting(release, "release");
                blocker.commit();
                heartbeat.get(10, TimeUnit.SECONDS);
                release.get(10, TimeUnit.SECONDS);
            }
            assertThat(activeCount(task)).isZero();
        }
    }

    @Test
    void heartbeatBeforeThresholdDoesNotIssueAnUpdateOrAuditEvent() {
        for (String type : TYPES) {
            Fixture task = seed(type, 25);
            var before = jdbc.queryForMap("SELECT xmin::text AS version, lease_until, last_heartbeat FROM task_claims WHERE id=?", task.id);
            as("heartbeat", owner, () -> service.heartbeat(task.type, task.key));
            assertThat(jdbc.queryForMap("SELECT xmin::text AS version, lease_until, last_heartbeat FROM task_claims WHERE id=?", task.id)).isEqualTo(before);
        }
        verifyNoInteractions(audit);
    }

    @Test
    void finishedSalesOrderAllowsCleanupButCannotRenewOrTakeOver() {
        Fixture task = seed("SALES_ORDER_FINANCE_CONFIRM", 1);
        jdbc.update("UPDATE sales_orders SET finance_confirmed=TRUE WHERE id=?", UUID.fromString(task.key));
        assertThatThrownBy(() -> as("heartbeat", owner, () -> service.heartbeat(task.type, task.key))).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> as("takeover", manager, () -> service.takeover(task.type, task.key))).isInstanceOf(ApiException.class);
        as("release", owner, () -> { service.release(task.type, task.key); return null; });
        assertThat(activeCount(task)).isZero();
    }

    @Test
    void expiredClaimReplacementFreesTheUniqueKeyBeforeInserting() {
        for (String type : TYPES) {
            Fixture task = seed(type, -1);
            as("claim", manager, () -> service.claim(task.type, task.key));
            assertThat(activeCount(task)).isEqualTo(1);
            assertThat(jdbc.queryForObject("SELECT release_reason FROM task_claims WHERE id=?", String.class, task.id)).isEqualTo("expired");
        }
    }

    private Fixture seed(String type, int remainingMinutes) {
        String key = UUID.randomUUID().toString();
        if (type.equals("SALES_ORDER_FINANCE_CONFIRM")) jdbc.update("INSERT INTO sales_orders(id) VALUES (?)", UUID.fromString(key));
        return transactions.execute(status -> {
            TaskClaim claim = new TaskClaim();
            claim.setTargetType(type); claim.setTargetKey(key); claim.setClaimedBy(owner);
            claim.setLeaseUntil(OffsetDateTime.now().plusMinutes(remainingMinutes));
            claim.setLastHeartbeat(OffsetDateTime.now().minusMinutes(2));
            repository.saveAndFlush(claim);
            return new Fixture(claim.getId(), type, key);
        });
    }

    private <T> T as(String label, UUID employee, Callable<T> action) {
        AuthUser user = new AuthUser(employee, employee, "test", Set.of(),
                Set.of("expense:approve", "sales_order_finance:view","sales_order_finance:confirm"), false, true, false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
        try { return transactions.execute(status -> {
            em.createNativeQuery("SELECT set_config('application_name', :name, true)").setParameter("name", "claim-test-" + label).getSingleResult();
            try { return action.call(); } catch (RuntimeException e) { throw e; }
            catch (Exception e) { throw new IllegalStateException(e); }
        }); } finally { SecurityContextHolder.clearContext(); }
    }

    private Connection lockClaim(Fixture task) throws Exception {
        Connection connection = jdbc.getDataSource().getConnection();
        connection.setAutoCommit(false);
        try (var statement = connection.prepareStatement("SELECT id FROM task_claims WHERE id=? FOR UPDATE")) {
            statement.setObject(1, task.id); statement.executeQuery();
        }
        return connection;
    }

    private static void assertLockWaiting(Future<?> future, String label) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8);
        while (System.nanoTime() < deadline) {
            if (future.isDone()) { future.get(); Assertions.fail("Mutation completed before its row lock was released"); }
            if (jdbc.queryForObject("SELECT count(*) FROM pg_stat_activity WHERE application_name=? AND wait_event_type='Lock'",
                    Long.class, "claim-test-" + label) > 0) return;
            TimeUnit.MILLISECONDS.sleep(20);
        }
        Assertions.fail("Mutation did not reach its database lock");
    }
    private static void assertConflict(Future<?> future) {
        assertThatThrownBy(() -> future.get(10, TimeUnit.SECONDS)).isInstanceOf(ExecutionException.class).hasCauseInstanceOf(ApiException.class);
    }
    private long activeCount(Fixture task) {
        return jdbc.queryForObject("SELECT count(*) FROM task_claims WHERE target_type=? AND target_key=? AND released_at IS NULL", Long.class, task.type, task.key);
    }
    private record Fixture(UUID id, String type, String key) {}
}
