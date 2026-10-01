package com.uten.imp.features.webinquiry;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.webinquiry.dto.IngestRequest;
import com.uten.imp.features.webinquiry.dto.StatusUpdateRequest;
import com.uten.imp.features.webinquiry.dto.WebsiteInquiryDetail;
import com.uten.imp.security.AuthUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.util.AopTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.Connection;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.junit.jupiter.api.Assertions.fail;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doCallRealMethod;

/** Real service proxies, repositories, client adapter, constraints and audit on a private migrated PG database. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev",
        "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false",
        "uten.jwt.secret=website-inquiry-race-jwt-test-only-0123456789",
        "uten.crypto.pgp-master-key=website-inquiry-race-pgp-test-only-0123456789",
        "uten.crypto.hmac-key=website-inquiry-race-hmac-test-only-0123456789",
        "uten.bootstrap.admin-login=website-inquiry-race-bootstrap",
        "uten.bootstrap.admin-password=WebsiteInquiryRaceTest-Only-1!"
})
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = WebsiteInquiryConcurrencyPostgresTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class WebsiteInquiryConcurrencyPostgresTest {
    private static final AtomicInteger ACTOR_SEQUENCE = new AtomicInteger();
    private static final Set<String> INQUIRY_PERMISSIONS = Set.of(
            "webinquiry:view", "webinquiry:claim", "webinquiry:close", "webinquiry:convert_client");
    private static MigratedSchemaBaseline.ScopedDatabase database;

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) throws java.sql.SQLException {
        database = MigratedSchemaBaseline.openDatabase("website_inquiry_race");
        registry.add("spring.datasource.url", database::getJdbcUrl);
        registry.add("spring.datasource.username", database::getUsername);
        registry.add("spring.datasource.password", database::getPassword);
    }

    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) throws java.sql.SQLException {
            if (database != null) database.close();
        }
    }

    @Autowired private WebsiteInquiryService service;
    @Autowired private WebsiteInquiryRepository repository;
    @Autowired private JdbcTemplate jdbc;
    @Autowired private EntityManager entityManager;
    @Autowired private PlatformTransactionManager transactionManager;
    @MockitoSpyBean private AuditService audit;
    private Actor first;
    private Actor second;

    @BeforeEach
    void actors() {
        first = actor("first", INQUIRY_PERMISSIONS);
        second = actor("second", INQUIRY_PERMISSIONS);
    }

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void twoConversionsCreateOneCustomerAndPreserveTheSourceAndExistingAssignee() throws Exception {
        Inquiry inquiry = inquiry();
        Actor assignee = actor("assigned", INQUIRY_PERMISSIONS);
        as(assignee, () -> service.updateStatus(inquiry.id(), new StatusUpdateRequest("following", "keep this note", true)));
        String firstLabel = label("convert1");
        String secondLabel = label("convert2");
        WebsiteInquiryDetail converted;
        WebsiteInquiryDetail replayed;
        try (var workers = Executors.newFixedThreadPool(2); Connection blocker = lockInquiry(inquiry.id())) {
            Future<WebsiteInquiryDetail> one = workers.submit(() -> inTransaction(firstLabel, first, () -> service.convert(inquiry.id())));
            assertLockWaiting(one, firstLabel);
            Future<WebsiteInquiryDetail> two = workers.submit(() -> inTransaction(secondLabel, second, () -> service.convert(inquiry.id())));
            assertLockWaiting(two, secondLabel);
            blocker.commit();
            converted = one.get(15, TimeUnit.SECONDS);
            replayed = two.get(15, TimeUnit.SECONDS);
        }
        assertThat(clientCount(inquiry)).as("one source must create exactly one customer").isEqualTo(1);
        assertThat(replayed.clientId()).isEqualTo(converted.clientId());
        assertThat(replayed.status()).isEqualTo("converted");
        assertThat(replayed.sourceId()).isEqualTo(inquiry.source());
        assertThat(replayed.assigneeEmployeeId()).isEqualTo(assignee.employee());
        assertThat(replayed.note()).isEqualTo("keep this note");
        assertClient(inquiry, converted.clientId(), first.employee());
        assertThat(conversionAudits(inquiry)).isEqualTo(1);
    }

    @ParameterizedTest
    @ValueSource(strings = {"new", "following", "closed"})
    void statusWaitingBehindConversionCannotEraseTheClientOrReopenTheInquiry(String status) throws Exception {
        Inquiry inquiry = inquiry();
        String convertLabel = label("convert");
        String statusLabel = label("status");
        WebsiteInquiryDetail converted;
        try (var workers = Executors.newFixedThreadPool(2); Connection blocker = lockInquiry(inquiry.id())) {
            Future<WebsiteInquiryDetail> one = workers.submit(() -> inTransaction(convertLabel, first, () -> service.convert(inquiry.id())));
            assertLockWaiting(one, convertLabel);
            Future<WebsiteInquiryDetail> two = workers.submit(() -> inTransaction(statusLabel, second,
                    () -> service.updateStatus(inquiry.id(), new StatusUpdateRequest(status, "late status", true))));
            assertLockWaiting(two, statusLabel);
            blocker.commit();
            converted = one.get(15, TimeUnit.SECONDS);
            assertConflict(two);
        }
        Map<String, Object> row = inquiryState(inquiry);
        assertThat(row.get("status")).isEqualTo("converted");
        assertThat(row.get("client_id")).isEqualTo(converted.clientId());
        assertThat(row.get("assignee_employee_id")).isEqualTo(first.employee());
        assertThat(row.get("note")).isNull();
        assertClient(inquiry, converted.clientId(), first.employee());
    }

    @Test
    void conversionWaitingBehindAClaimPreservesTheWinningAssigneeAndNote() throws Exception {
        Inquiry inquiry = inquiry();
        String claimLabel = label("claim");
        String convertLabel = label("convert");
        WebsiteInquiryDetail converted;
        try (var workers = Executors.newFixedThreadPool(2); Connection blocker = lockInquiry(inquiry.id())) {
            Future<WebsiteInquiryDetail> claim = workers.submit(() -> inTransaction(claimLabel, second,
                    () -> service.updateStatus(inquiry.id(), new StatusUpdateRequest("following", "claimed before conversion", true))));
            assertLockWaiting(claim, claimLabel);
            Future<WebsiteInquiryDetail> convert = workers.submit(() -> inTransaction(convertLabel, first, () -> service.convert(inquiry.id())));
            assertLockWaiting(convert, convertLabel);
            blocker.commit();
            claim.get(15, TimeUnit.SECONDS);
            converted = convert.get(15, TimeUnit.SECONDS);
        }
        assertThat(converted.assigneeEmployeeId()).isEqualTo(second.employee());
        assertThat(converted.note()).isEqualTo("claimed before conversion");
        assertClient(inquiry, converted.clientId(), first.employee());
    }

    @Test
    void conversionLocksItsClientOwnerBeforeTheInquiryAndKeepsAHandoverAssignee() throws Exception {
        Inquiry inquiry = inquiry();
        as(first, () -> service.updateStatus(inquiry.id(), new StatusUpdateRequest("following", null, true)));
        String convertLabel = label("handover-convert");
        try (var worker = Executors.newSingleThreadExecutor(); Connection handover = lockHandoverEmployees()) {
            Future<WebsiteInquiryDetail> convert = worker.submit(() -> inTransaction(convertLabel, first, () -> service.convert(inquiry.id())));
            assertLockWaiting(convert, convertLabel);
            // Same employee -> inquiry order as DataHandoverService, on real PG.
            // NOWAIT proves the waiting converter has not taken the inquiry first.
            handoverAssignee(handover, inquiry.id());
            handover.commit();
            WebsiteInquiryDetail converted = convert.get(15, TimeUnit.SECONDS);
            assertThat(converted.assigneeEmployeeId()).isEqualTo(second.employee());
            assertThat(converted.note()).isEqualTo("handed over");
            assertClient(inquiry, converted.clientId(), first.employee());
        }
    }

    @Test
    void aStatusKeepingItsAssigneeConflictsAfterHandoverWithoutReversingTheEmployeeLockOrder() throws Exception {
        Inquiry inquiry = inquiry();
        as(first, () -> service.updateStatus(inquiry.id(), new StatusUpdateRequest("following", null, true)));
        String statusLabel = label("handover-status");
        try (var worker = Executors.newSingleThreadExecutor(); Connection handover = lockHandoverEmployees()) {
            Future<WebsiteInquiryDetail> status = worker.submit(() -> inTransaction(statusLabel, second,
                    () -> service.updateStatus(inquiry.id(), new StatusUpdateRequest("following", "stale note", false))));
            assertLockWaiting(status, statusLabel);
            handoverAssignee(handover, inquiry.id());
            handover.commit();
            assertConflict(status);
        }
        Map<String, Object> row = inquiryState(inquiry);
        assertThat(row.get("assignee_employee_id")).isEqualTo(second.employee());
        assertThat(row.get("note")).isEqualTo("handed over");
        assertThat(clientCount(inquiry)).isZero();
    }

    @Test
    void anAlreadyManagedInquiryIsRefreshedBeforeDecidingToCreateAClient() throws Exception {
        Inquiry inquiry = inquiry();
        CountDownLatch preloaded = new CountDownLatch(1);
        CountDownLatch proceed = new CountDownLatch(1);
        try (var worker = Executors.newSingleThreadExecutor()) {
            Future<WebsiteInquiryDetail> staleReader = worker.submit(() -> inTransaction(label("preloaded"), second, () -> {
                assertThat(repository.findById(inquiry.id()).orElseThrow().getClientId()).isNull();
                preloaded.countDown();
                assertThat(proceed.await(15, TimeUnit.SECONDS)).isTrue();
                return service.convert(inquiry.id());
            }));
            try {
                assertThat(preloaded.await(10, TimeUnit.SECONDS)).isTrue();
                WebsiteInquiryDetail committed = as(first, () -> service.convert(inquiry.id()));
                proceed.countDown();
                assertThat(staleReader.get(15, TimeUnit.SECONDS).clientId()).isEqualTo(committed.clientId());
                assertClient(inquiry, committed.clientId(), first.employee());
            } finally {
                proceed.countDown();
            }
        }
    }

    @Test
    void auditFailureRollsBackTheRealClientAndInquiryAndAFreshRetryCreatesOneClient() throws Exception {
        Inquiry inquiry = inquiry();
        doAnswer(invocation -> {
            invocation.callRealMethod();
            entityManager.flush();
            throw new IllegalStateException("inquiry test failure after real client and audit writes");
        }).when(auditTarget()).logCommitted(any(), anyString(), eq("webinquiry_convert"), eq("website_inquiry"), anyString(), eq("success"));
        // No caller-owned TransactionTemplate: the production service proxy owns this rollback.
        assertThatThrownBy(() -> as(first, () -> service.convert(inquiry.id())))
                .isInstanceOf(IllegalStateException.class).hasMessageContaining("inquiry test failure");
        assertThat(clientCount(inquiry)).isZero();
        assertThat(conversionAudits(inquiry)).isZero();
        Map<String, Object> unchanged = inquiryState(inquiry);
        assertThat(unchanged.get("status")).isEqualTo("new");
        assertThat(unchanged.get("client_id")).isNull();
        assertThat(unchanged.get("assignee_employee_id")).isNull();

        doCallRealMethod().when(auditTarget()).logCommitted(any(), anyString(), eq("webinquiry_convert"), eq("website_inquiry"), anyString(), eq("success"));
        WebsiteInquiryDetail retried = as(first, () -> service.convert(inquiry.id()));
        assertClient(inquiry, retried.clientId(), first.employee());
        assertThat(conversionAudits(inquiry)).isEqualTo(1);
    }

    @Test
    void actionPermissionsAreEnforcedBeforeConversionAndMixedStatusClaimWrites() throws Exception {
        Inquiry inquiry = inquiry();
        Actor viewer = actor("view", Set.of("webinquiry:view"));
        Actor closer = actor("close", Set.of("webinquiry:close"));
        Actor claimant = actor("claim", Set.of("webinquiry:claim"));
        assertThatThrownBy(() -> as(viewer, () -> service.convert(inquiry.id()))).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> as(closer, () -> service.updateStatus(inquiry.id(),
                new StatusUpdateRequest("closed", null, true)))).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> as(claimant, () -> service.updateStatus(inquiry.id(),
                new StatusUpdateRequest("closed", null, false)))).isInstanceOf(AccessDeniedException.class);
        assertThat(clientCount(inquiry)).isZero();
        assertThat(inquiryState(inquiry).get("status")).isEqualTo("new");
        Actor converter = actor("convert", Set.of("webinquiry:convert_client"));
        assertClient(inquiry, as(converter, () -> service.convert(inquiry.id())).clientId(), converter.employee());
    }

    @Test
    void simultaneousDeliveriesOfTheSameSourceAreSuccessfulAndKeepTheFirstSnapshot() throws Exception {
        String source = "web-race-" + UUID.randomUUID();
        String firstLabel = label("ingest1");
        String secondLabel = label("ingest2");
        try (var workers = Executors.newFixedThreadPool(2); Connection blocker = database.openConnection()) {
            blocker.setAutoCommit(false);
            // Block INSERT, not SELECT, to expose the old absent-row check/insert race.
            try (var statement = blocker.createStatement()) {
                statement.execute("LOCK TABLE website_inquiries IN SHARE MODE");
            }
            Future<Boolean> one = workers.submit(() -> inTransaction(firstLabel, first, () -> service.ingest(request(source, "first snapshot"))));
            assertLockWaiting(one, firstLabel);
            Future<Boolean> two = workers.submit(() -> inTransaction(secondLabel, second, () -> service.ingest(request(source, "replayed payload"))));
            assertLockWaiting(two, secondLabel);
            blocker.commit();
            assertThat(one.get(15, TimeUnit.SECONDS)).isTrue();
            assertThat(two.get(15, TimeUnit.SECONDS)).isFalse();
        }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM website_inquiries WHERE source_id=?", Long.class, source)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT message FROM website_inquiries WHERE source_id=?", String.class, source)).isEqualTo("first snapshot");
    }

    private Inquiry inquiry() throws Exception {
        String source = "web-race-" + UUID.randomUUID();
        assertThat(as(first, () -> service.ingest(request(source, "original inquiry")))).isTrue();
        return new Inquiry(jdbc.queryForObject("SELECT id FROM website_inquiries WHERE source_id=?", UUID.class, source), source);
    }

    private static IngestRequest request(String source, String message) {
        return new IngestRequest(source, "Inquiry Contact", "test-phone", "inquiry@example.invalid", "Inquiry Company",
                "EU", "distributor", "BS", "Q7", "quotation", "5000", "2026-Q4", "email", message, "contact", "en");
    }

    private Actor actor(String label, Set<String> permissions) {
        int sequence = ACTOR_SEQUENCE.incrementAndGet();
        UUID employee = UUID.randomUUID();
        UUID user = UUID.randomUUID();
        String login = "web-race-" + label + "-" + user;
        UUID department = jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_SALES'", UUID.class);
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')
                """, employee, "EMP-WEB-RACE-" + sequence, "询盘并发测试-" + sequence, department);
        jdbc.update("""
                INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status)
                VALUES(?,?,?,'test-only-not-used',false,false,'active')
                """, user, employee, login);
        return new Actor(user, employee, login, permissions);
    }

    private <T> T as(Actor actor, Callable<T> work) throws Exception {
        AuthUser principal = new AuthUser(actor.user(), actor.employee(), actor.login(), actor.permissions(), false, true, false);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(principal, null, principal.getAuthorities()));
        try { return work.call(); }
        finally { SecurityContextHolder.clearContext(); }
    }

    private <T> T inTransaction(String label, Actor actor, Callable<T> work) throws Exception {
        return as(actor, () -> {
            TransactionTemplate transaction = new TransactionTemplate(transactionManager);
            transaction.setTimeout(30);
            return transaction.execute(status -> {
                jdbc.queryForObject("SELECT set_config('application_name', ?, true)", String.class, label);
                jdbc.execute("SET LOCAL lock_timeout='20s'");
                try { return work.call(); }
                catch (RuntimeException failure) { throw failure; }
                catch (Exception failure) { throw new IllegalStateException(failure); }
            });
        });
    }

    private Connection lockInquiry(UUID id) throws Exception {
        Connection connection = database.openConnection();
        connection.setAutoCommit(false);
        try (var statement = connection.prepareStatement("SELECT id FROM website_inquiries WHERE id=? FOR UPDATE")) {
            statement.setObject(1, id);
            statement.executeQuery().close();
        }
        return connection;
    }

    private Connection lockHandoverEmployees() throws Exception {
        Connection connection = database.openConnection();
        connection.setAutoCommit(false);
        try (var statement = connection.prepareStatement("SELECT id FROM employees WHERE id IN (?,?) ORDER BY id FOR UPDATE")) {
            statement.setObject(1, first.employee());
            statement.setObject(2, second.employee());
            statement.executeQuery().close();
        }
        return connection;
    }

    private void handoverAssignee(Connection connection, UUID inquiryId) throws Exception {
        try (var statement = connection.prepareStatement("SELECT id FROM website_inquiries WHERE id=? FOR UPDATE NOWAIT")) {
            statement.setObject(1, inquiryId);
            statement.executeQuery().close();
        }
        try (var statement = connection.prepareStatement("""
                UPDATE website_inquiries SET assignee_employee_id=?,note='handed over'
                WHERE id=? AND assignee_employee_id=? AND status IN ('new','following')
                """)) {
            statement.setObject(1, second.employee());
            statement.setObject(2, inquiryId);
            statement.setObject(3, first.employee());
            assertThat(statement.executeUpdate()).isEqualTo(1);
        }
    }

    private void assertLockWaiting(Future<?> future, String label) throws Exception {
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (System.nanoTime() < until) {
            if (future.isDone()) {
                future.get();
                fail("Command completed before the test released its database lock");
            }
            Long waiting = jdbc.queryForObject("SELECT count(*) FROM pg_stat_activity WHERE application_name=? AND wait_event_type='Lock'", Long.class, label);
            if (waiting != null && waiting > 0) return;
            TimeUnit.MILLISECONDS.sleep(20);
        }
        fail("Command did not reach its database lock: " + label);
    }

    private static void assertConflict(Future<?> future) throws Exception {
        try {
            future.get(15, TimeUnit.SECONDS);
            fail("Waiting status command overwrote the converted inquiry");
        } catch (ExecutionException failure) {
            assertThat(failure.getCause()).isInstanceOf(ApiException.class);
            assertThat(((ApiException) failure.getCause()).getCode()).isEqualTo(ErrorCode.CONFLICT);
        }
    }

    private void assertClient(Inquiry inquiry, UUID client, UUID owner) {
        assertThat(client).isNotNull();
        assertThat(clientCount(inquiry)).isEqualTo(1);
        Map<String, Object> saved = jdbc.queryForMap("SELECT owner_employee_id,name,linkman,mobile,remark FROM clients WHERE id=?", client);
        assertThat(saved.get("owner_employee_id")).isEqualTo(owner);
        assertThat(saved.get("name")).isEqualTo("Inquiry Company");
        assertThat(saved.get("linkman")).isEqualTo("Inquiry Contact");
        assertThat(saved.get("mobile")).isEqualTo("test-phone");
        assertThat(saved.get("remark")).isEqualTo("来源：官网询盘 " + inquiry.source());
        assertThat(inquiryState(inquiry).get("client_id")).isEqualTo(client);
        assertThat(jdbc.queryForObject("SELECT source_id FROM website_inquiries WHERE id=?", String.class, inquiry.id())).isEqualTo(inquiry.source());
    }

    private long clientCount(Inquiry inquiry) {
        return jdbc.queryForObject("SELECT count(*) FROM clients WHERE remark=?", Long.class, "来源：官网询盘 " + inquiry.source());
    }

    private long conversionAudits(Inquiry inquiry) {
        return jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action='webinquiry_convert' AND target_id LIKE ?", Long.class,
                "询价=" + inquiry.id() + "；客户=%");
    }

    private AuditService auditTarget() {
        return AopTestUtils.getUltimateTargetObject(audit);
    }

    private Map<String, Object> inquiryState(Inquiry inquiry) {
        return jdbc.queryForMap("SELECT status,client_id,assignee_employee_id,note FROM website_inquiries WHERE id=?", inquiry.id());
    }

    private static String label(String action) { return "web-race-" + action + "-" + UUID.randomUUID(); }
    private record Inquiry(UUID id, String source) { }
    private record Actor(UUID user, UUID employee, String login, Set<String> permissions) { }
}
