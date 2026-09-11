package com.uten.imp.features.visitor;

import com.uten.imp.features.notice.HrNoticeService;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.HostConfirmRequest;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorApproveRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
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
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.Properties;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.*;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/** Real production repository locks and services against an isolated PostgreSQL schema. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class VisitorAdmissionConcurrencyPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static EntityManagerFactory emf;
    private static TransactionTemplate transactions;
    private static JdbcTemplate jdbc;
    private static VisitorApplicationRepository applications;
    private static VisitorAccountRepository accounts;
    private static VisitorApprovalStepRepository steps;

    private VisitorGateService gate;
    private VisitorHrApprovalService approvals;
    private VisitorHostConfirmService host;
    private UUID accountId;
    private UUID applicationId;
    private final UUID employeeId = UUID.randomUUID();

    @BeforeAll
    static void start() {
        DB.start();
        var dataSource = new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        var factory = new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(dataSource);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setPackagesToScan("com.uten.imp.features.visitor");
        var properties = new Properties();
        properties.setProperty("hibernate.hbm2ddl.auto", "create-drop");
        properties.setProperty("hibernate.jdbc.time_zone", "UTC");
        factory.setJpaProperties(properties);
        factory.afterPropertiesSet();
        emf = factory.getObject();
        transactions = new TransactionTemplate(new JpaTransactionManager(emf));
        transactions.setTimeout(15);
        var repositoryFactory = new JpaRepositoryFactory(SharedEntityManagerCreator.createSharedEntityManager(emf));
        applications = repositoryFactory.getRepository(VisitorApplicationRepository.class);
        accounts = repositoryFactory.getRepository(VisitorAccountRepository.class);
        steps = repositoryFactory.getRepository(VisitorApprovalStepRepository.class);
    }

    @AfterAll
    static void stop() {
        if (emf != null) emf.close();
        DB.stop();
    }

    @BeforeEach
    void seed() {
        var tx = mock(TxSessionVars.class);
        when(tx.hmac(anyString())).thenReturn("a".repeat(64));
        var current = mock(SecurityContextCurrentUser.class);
        UUID actor = UUID.randomUUID();
        when(current.id()).thenReturn(Optional.of(actor));
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor, employeeId, "test",
                Set.of(), Set.of("visitor:approve", "visitor:host-confirm", "visitor:check-in"), false, true, false)));
        var mapper = mock(VisitorApplicationMapper.class);
        when(mapper.hostInfo(any())).thenReturn(new String[]{"Host", "Department"});
        // 2026-09-10：HrNoticeService 与业务同事务且不再吞异常，裸 null 依赖会让
        // 申请/审批因 NPE 回滚；本测试只验证准入并发，通知用 mock 隔离。
        var hrNotice = mock(HrNoticeService.class);
        var service = new VisitorApplicationService(applications, steps, accounts,
                mock(EmployeeRepository.class), mapper, tx, hrNotice, current);
        var guard = new VisitorGuard(current);
        gate = new VisitorGateService(applications, accounts, service, mapper, guard, tx, current, new ObjectMapper());
        approvals = new VisitorHrApprovalService(applications, service, gate, guard, tx, hrNotice);
        host = new VisitorHostConfirmService(applications, service, current, tx, hrNotice);
        transactions.executeWithoutResult(status -> {
            var account = new VisitorAccount();
            account.setPhoneEnc("test-phone"); account.setPhoneHash(UUID.randomUUID().toString());
            account.setName("Visitor"); account.setVisitorNo(UUID.randomUUID().toString());
            accounts.saveAndFlush(account); accountId = account.getId();
            var app = new VisitorApplication();
            app.setVisitorAccountId(accountId); app.setVisitorName("Visitor"); app.setVisitPurpose("meeting");
            app.setPlannedVisitAt(OffsetDateTime.now().plusHours(1)); app.setHostEmployeeId(employeeId);
            applications.saveAndFlush(app); applicationId = app.getId();
        });
    }

    @Test
    void laterApprovalAndHostConfirmationCannotRewriteTheWinningApproval() throws Exception {
        for (boolean hostConfirmation : new boolean[]{false, true}) {
            jdbc.update("UPDATE visitor_applications SET status='pending' WHERE id=?", applicationId);
            try (var executor = Executors.newFixedThreadPool(2); Connection blocker = lockAccount()) {
                Future<?> first = executor.submit(() -> inTransaction(() -> approve()));
                assertBlocked(first);
                Future<?> later = executor.submit(() -> inTransaction(() -> hostConfirmation
                        ? host.hostConfirm(applicationId, new HostConfirmRequest(true, "late host"))
                        : approvals.handleAction(applicationId, new VisitorApproveRequest("reject", "late review", "late"))));
                assertBlocked(later);
                blocker.commit();
                first.get(10, TimeUnit.SECONDS);
                assertBusinessRejection(later);
            }
            assertThat(state()).isEqualTo("approved");
        }
    }

    @Test
    void delayedApprovalCannotReviveAnAlreadyCheckedInApplication() throws Exception {
        inTransaction(this::approve);
        try (var executor = Executors.newFixedThreadPool(2); Connection blocker = lockAccount()) {
            Future<?> first = executor.submit(() -> inTransaction(() -> gate.checkIn(applicationId)));
            assertBlocked(first);
            Future<?> lateApproval = executor.submit(() -> inTransaction(this::approve));
            assertBlocked(lateApproval);
            blocker.commit();
            first.get(10, TimeUnit.SECONDS);
            assertBusinessRejection(lateApproval);
        }
        assertThat(state()).isEqualTo("checkedIn");
        assertThat(jdbc.queryForObject("SELECT check_in_at IS NOT NULL FROM visitor_applications WHERE id=?", Boolean.class, applicationId)).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM visitor_approval_steps WHERE application_id=? AND action='checkIn'", Long.class, applicationId)).isEqualTo(1);
    }

    @Test
    void blacklistWinsAgainstWaitingAdmissionWithoutChangingTheApplicationHistory() throws Exception {
        inTransaction(this::approve);
        try (var executor = Executors.newFixedThreadPool(2); Connection blocker = lockAccount()) {
            Future<?> blacklist = executor.submit(() -> transactions.executeWithoutResult(s -> gate.blacklist(accountId)));
            assertBlocked(blacklist);
            Future<?> admission = executor.submit(() -> inTransaction(() -> gate.checkIn(applicationId)));
            assertBlocked(admission);
            blocker.commit();
            blacklist.get(10, TimeUnit.SECONDS);
            Object result = admission.get(10, TimeUnit.SECONDS);
            assertThat(((com.uten.imp.features.visitor.dto.VisitorScanDto.VisitorVerifyResponse) result).reason()).isEqualTo("blocked");
        }
        assertThat(state()).isEqualTo("approved");
        assertThat(jdbc.queryForObject("SELECT check_in_at IS NULL FROM visitor_applications WHERE id=?", Boolean.class, applicationId)).isTrue();
    }

    @Test
    void admissionWinningBeforeBlacklistKeepsItsOriginalCheckedInEvidence() throws Exception {
        inTransaction(this::approve);
        try (var executor = Executors.newFixedThreadPool(2); Connection blocker = lockAccount()) {
            Future<?> admission = executor.submit(() -> inTransaction(() -> gate.checkIn(applicationId)));
            assertBlocked(admission);
            Future<?> blacklist = executor.submit(() -> transactions.executeWithoutResult(s -> gate.blacklist(accountId)));
            assertBlocked(blacklist);
            blocker.commit();
            admission.get(10, TimeUnit.SECONDS);
            blacklist.get(10, TimeUnit.SECONDS);
        }
        assertThat(state()).isEqualTo("checkedIn");
        assertThat(jdbc.queryForObject("SELECT status FROM visitor_accounts WHERE id=?", String.class, accountId)).isEqualTo("blocked");
    }

    private Object approve() { return approvals.handleAction(applicationId, new VisitorApproveRequest("approve", null, null)); }
    private <T> T inTransaction(Callable<T> action) { return transactions.execute(status -> {
        try { return action.call(); } catch (RuntimeException e) { throw e; }
        catch (Exception e) { throw new IllegalStateException(e); }
    }); }
    private Connection lockAccount() throws Exception {
        Connection connection = jdbc.getDataSource().getConnection();
        connection.setAutoCommit(false);
        try (var statement = connection.prepareStatement("SELECT id FROM visitor_accounts WHERE id=? FOR UPDATE")) {
            statement.setObject(1, accountId); statement.executeQuery();
        }
        return connection;
    }
    private static void assertBlocked(Future<?> future) {
        assertThatThrownBy(() -> future.get(200, TimeUnit.MILLISECONDS)).isInstanceOf(TimeoutException.class);
    }
    private static void assertBusinessRejection(Future<?> future) {
        assertThatThrownBy(() -> future.get(10, TimeUnit.SECONDS)).isInstanceOf(ExecutionException.class)
                .hasCauseInstanceOf(ApiException.class);
    }
    private String state() { return jdbc.queryForObject("SELECT status FROM visitor_applications WHERE id=?", String.class, applicationId); }
}
