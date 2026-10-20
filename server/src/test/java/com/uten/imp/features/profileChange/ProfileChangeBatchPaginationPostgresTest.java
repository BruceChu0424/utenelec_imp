package com.uten.imp.features.profilechange;

import com.uten.imp.application.port.HrNoticePort;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.auth.StepUpService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.profilechange.dto.ProfileChangeDto;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.jdbc.test.autoconfigure.AutoConfigureTestDatabase;
import org.springframework.boot.data.jpa.test.autoconfigure.DataJpaTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.test.context.transaction.TestTransaction;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.context.annotation.Import;
import com.uten.imp.config.JpaAuditingConfig;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.testcontainers.containers.PostgreSQLContainer;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Actual JPA/native SQL proof: the queue's unit is a complete submitted batch. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = ProfileChangeBatchPaginationPostgresTest.DatabaseCleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
@DataJpaTest(properties = {
        "spring.jpa.hibernate.ddl-auto=none",
        "spring.flyway.enabled=true",
        "spring.jpa.show-sql=false",
        "logging.level.org.hibernate.SQL=OFF"
})
@Import({JpaAuditingConfig.class, com.uten.imp.security.SecurityContextCurrentUser.class})
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
class ProfileChangeBatchPaginationPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("profile_batch_pages").withUsername("uten").withPassword("uten");

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    public static class DatabaseCleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) { POSTGRES.stop(); }
    }

    @Autowired ProfileChangeRepository repository;
    @Autowired EmployeeRepository employees;
    @Autowired JdbcTemplate jdbc;
    @Autowired EntityManager entityManager;
    @Autowired PlatformTransactionManager transactionManager;
    private ProfileChangeQueryService queries;
    private ProfileChangeReviewService reviews;
    private ProfileChangeAccess access;
    private ProfileFieldApplier applier;
    private ProfileChangeSnapshotCodec codec;
    private HrNoticePort notices;
    private TxSessionVars tx;
    private UUID departmentA;
    private UUID departmentB;
    private UUID employeeA;
    private UUID employeeB;

    @BeforeEach
    void setup() {
        jdbc.execute("SELECT set_config('app.profile_change_snapshot_codec', 'v1', true)");
        departmentA = department("A");
        departmentB = department("B");
        employeeA = employee(departmentA, "A");
        employeeB = employee(departmentB, "B");
        access = mock(ProfileChangeAccess.class);
        AuthUser user = mock(AuthUser.class);
        when(user.getId()).thenReturn(UUID.randomUUID());
        when(user.getEmployeeId()).thenReturn(employeeA);
        when(access.requireStaff()).thenReturn(user);
        when(access.requireHr()).thenReturn(user);
        when(access.hasReviewPerm()).thenReturn(true);
        codec = mock(ProfileChangeSnapshotCodec.class);
        when(codec.decode(anyString(), anyString(), anyString())).thenAnswer(call -> call.getArgument(2));
        when(codec.encodingFor(anyString())).thenReturn("PLAIN");
        when(codec.encode(anyString(), any())).thenAnswer(call -> call.getArgument(1));
        ProfileChangeMapper mapper = new ProfileChangeMapper(employees, codec);
        notices = mock(HrNoticePort.class);
        tx = mock(TxSessionVars.class);
        applier = mock(ProfileFieldApplier.class);
        when(applier.readCurrentValue(any(), eq("fullName"))).thenAnswer(call -> ((com.uten.imp.features.org.employee.Employee) call.getArgument(0)).getFullName());
        when(applier.readCurrentValue(any(), eq("seatNo"))).thenAnswer(call -> ((com.uten.imp.features.org.employee.Employee) call.getArgument(0)).getSeatNo());
        doAnswer(call -> { ((com.uten.imp.features.org.employee.Employee) call.getArgument(0)).setSeatNo(call.getArgument(2)); return null; })
                .when(applier).applyDirectEdit(any(), eq("seatNo"), anyString());
        doAnswer(call -> { var row = (ProfileChangeRequest) call.getArgument(1); if ("fullName".equals(row.getFieldCode())) { ((com.uten.imp.features.org.employee.Employee) call.getArgument(0)).setFullName(row.getNewValueEnc()); } return null; })
                .when(applier).applyReviewedChange(any(), any());
        queries = new ProfileChangeQueryService(repository, mapper, codec, access, tx, notices);
        UserAccountRepository accounts = mock(UserAccountRepository.class);
        when(accounts.findByEmployeeId(any())).thenReturn(Optional.empty());
        reviews = new ProfileChangeReviewService(repository, employees, accounts,
                mock(NoticeService.class), notices, applier,
                mapper, codec, access, tx);
    }

    @Test
    void historyPagesUseAggregateBatchStateAndKeepMineAndDepartmentScopes() {
        UUID pending = batch(employeeA, "pending", 2, OffsetDateTime.now());
        jdbc.update("UPDATE profile_change_requests SET status = 'rejected' WHERE batch_id = ? AND field_code = 'testField0'", pending);
        List<UUID> mineHistory = List.of(
                batch(employeeA, "applied", 2, OffsetDateTime.now().minusMinutes(1)),
                batch(employeeA, "rejected", 1, OffsetDateTime.now().minusMinutes(2)),
                batch(employeeA, "cancelled", 1, OffsetDateTime.now().minusMinutes(3)),
                batch(employeeA, "approved", 1, OffsetDateTime.now().minusMinutes(4)));
        batch(employeeB, "applied", 1, OffsetDateTime.now().minusMinutes(5));
        entityManager.clear();
        var active = queries.myList(1, 1, null);
        assertEquals(1, active.totalElements());
        assertEquals(pending, active.items().getFirst().batchId());
        assertEquals(2, active.items().getFirst().itemCount());
        var mine = queries.myList(1, 1, "history");
        assertEquals(4, mine.totalElements());
        assertEquals(4, mine.totalPages());
        List<UUID> paged = java.util.stream.IntStream.rangeClosed(1, 4)
                .mapToObj(page -> queries.myList(page, 1, "history").items().getFirst().batchId()).toList();
        assertEquals(mineHistory, paged);
        assertEquals(4, queries.hrList(1, 1, "history", null, departmentA).totalElements());
        assertEquals(1, queries.hrList(1, 1, "history", employeeB, departmentB).totalElements());
        assertEquals(0, queries.hrList(1, 1, "history", employeeA, departmentB).totalElements());
        assertEquals(5, queries.hrFacets("history").departments().stream().mapToLong(bucket -> bucket.count()).sum());
        assertEquals(1, queries.hrFacets("pending").departments().stream().mapToLong(bucket -> bucket.count()).sum());
    }

    @Test
    void completeBatchSurvivesPageSizeOneAndEveryCounterUsesBatchGrain() {
        UUID newest = batch(employeeA, "pending", 3, OffsetDateTime.parse("2026-10-12T10:00:00Z"));
        UUID older = batch(employeeB, "pending", 2, OffsetDateTime.parse("2026-10-12T09:00:00Z"));
        var first = queries.hrList(1, 1, null, null, null);
        var second = queries.hrList(2, 1, null, null, null);
        assertEquals(2, first.totalElements());
        assertEquals(2, first.totalPages());
        assertEquals(newest, first.items().getFirst().batchId());
        assertEquals(3, first.items().getFirst().itemCount());
        assertEquals(3, first.items().getFirst().fieldCodes().size());
        assertEquals(older, second.items().getFirst().batchId());
        assertEquals(2, second.items().getFirst().itemCount());
        assertEquals(2, reviews.pendingCount());
        assertEquals(1, reviews.pendingCountForEmployee(employeeA));
        assertEquals(2, queries.hrFacets("pending").departments().stream().mapToLong(bucket -> bucket.count()).sum());
        assertEquals(1, queries.hrList(1, 1, "pending", null, departmentA).totalElements());
        assertEquals(1, queries.hrList(1, 1, "pending", employeeB, departmentB).totalElements());
        assertEquals(0, queries.hrList(1, 1, "pending", employeeB, departmentA).totalElements());
        var mine = queries.myList(1, 1, null);
        assertEquals(1, mine.totalElements());
        assertEquals(newest, mine.items().getFirst().batchId());
        assertEquals(3, mine.items().getFirst().itemCount());
    }

    @Test
    void approveAndRejectRemoveOneWholeBatchAndPreserveItsCompleteHistory() {
        UUID approved = batch(employeeA, "pending", 3, OffsetDateTime.now());
        UUID rejected = batch(employeeB, "pending", 2, OffsetDateTime.now().minusMinutes(1));
        assertEquals(2, reviews.pendingCount());
        var approval = reviews.review(approved, new com.uten.imp.features.profilechange.dto.ProfileChangeDto.ReviewAction("approve", null));
        assertEquals("applied", approval.status());
        assertEquals(3, approval.itemCount());
        assertEquals(1, reviews.pendingCount());
        assertEquals(0, reviews.pendingCountForEmployee(employeeA));
        var rejection = reviews.review(rejected, new com.uten.imp.features.profilechange.dto.ProfileChangeDto.ReviewAction("reject", "资料不完整"));
        assertEquals("rejected", rejection.status());
        assertEquals(2, rejection.itemCount());
        assertEquals(0, reviews.pendingCount());
        assertTrue(queries.hrList(1, 1, null, null, null).items().isEmpty());
        assertTrue(queries.hrFacets("pending").departments().isEmpty());
        assertEquals(approved, queries.hrList(1, 1, "applied", null, null).items().getFirst().batchId());
        assertEquals(rejected, queries.hrList(1, 1, "rejected", null, null).items().getFirst().batchId());
        assertEquals(0, queries.myList(1, 1, "pending").totalElements());
        assertEquals(1, queries.myList(1, 1, "applied").totalElements());
        when(access.hasReviewPerm()).thenReturn(false);
        assertEquals(0, reviews.pendingCount());
        assertEquals(0, reviews.pendingCountForEmployee(employeeA));
    }

    @Test
    void sameTimePagesAreStableAndMixedHistoricalRowsFollowTheBatchStatus() {
        OffsetDateTime sameTime = OffsetDateTime.parse("2026-10-12T10:00:00Z");
        UUID a = batch(employeeA, "pending", 3, sameTime);
        UUID b = batch(employeeB, "pending", 1, sameTime);
        var first = queries.hrList(1, 1, "pending", null, null).items().getFirst().batchId();
        var second = queries.hrList(2, 1, "pending", null, null).items().getFirst().batchId();
        assertNotEquals(first, second);
        assertTrue(List.of(a, b).contains(first));
        assertTrue(List.of(a, b).contains(second));
        jdbc.update("UPDATE profile_change_requests SET status = 'rejected' WHERE batch_id = ? AND field_code = 'testField0'", a);
        entityManager.clear();
        assertEquals(2, reviews.pendingCount(), "未办字段使整个历史混合批次继续待办");
        assertEquals(2, queries.hrList(1, 1, "pending", null, null).totalElements());
        assertTrue(queries.hrList(1, 1, "rejected", null, null).items().isEmpty());
        var active = queries.hrBatchDetail(a);
        assertEquals(3, active.itemCount());
        assertEquals("pending", active.status());
        assertEquals(2, queries.hrFacets("pending").departments().stream().mapToLong(bucket -> bucket.count()).sum());
    }

    @Test
    void mixedDirectAndReviewSubmissionReplaysTheWholeReceiptAndSnapshotsTheCommittedVersion() {
        var submit = submissions(access);
        UUID batchId = UUID.randomUUID();
        String key = UUID.randomUUID().toString();
        var request = new ProfileChangeDto.SubmitRequest(batchId, List.of(
                new ProfileChangeDto.FieldChange("seatNo", "座位", "A-12"),
                new ProfileChangeDto.FieldChange("fullName", "姓名", "审核后姓名")), key);
        var receipt = submit.submit(request);
        entityManager.flush();
        assertEquals(1, receipt.count());
        assertEquals(1, employees.findById(employeeA).orElseThrow().getVersion());
        assertEquals(1, repository.findByBatchId(batchId).getFirst().getEmployeeVersion());
        var replay = submit.submit(request);
        assertEquals(receipt, replay);
        assertEquals(1, repository.findByBatchId(batchId).size());
        assertEquals(1, employees.findById(employeeA).orElseThrow().getVersion());
        assertThrows(ApiException.class, () -> submit.submit(new ProfileChangeDto.SubmitRequest(batchId, List.of(
                new ProfileChangeDto.FieldChange("seatNo", "座位", "B-99"),
                new ProfileChangeDto.FieldChange("fullName", "姓名", "审核后姓名")), key)));
        assertThrows(ApiException.class, () -> submit.submit(new ProfileChangeDto.SubmitRequest(batchId, List.of(
                new ProfileChangeDto.FieldChange("seatNo", "座位", "A-12"),
                new ProfileChangeDto.FieldChange("fullName", "姓名", "另一姓名")), key)));
        var result = reviews.review(batchId, new ProfileChangeDto.ReviewAction("approve", null));
        assertEquals("applied", result.status(), "直改+待审不能由自身version变化造成409");
        assertEquals("审核后姓名", employees.findById(employeeA).orElseThrow().getFullName());
        assertEquals(2, employees.findById(employeeA).orElseThrow().getVersion());
        assertEquals(receipt, submit.submit(request), "已经办结的合法重放仍回原回执");
        assertThrows(ApiException.class, () -> submit.submit(new ProfileChangeDto.SubmitRequest(batchId,
                List.of(new ProfileChangeDto.FieldChange("fullName", "姓名", "追加到已审批次")), UUID.randomUUID().toString())));
        assertEquals(1, repository.findByBatchId(batchId).size());
    }

    @Test
    void foreignBatchAndIdempotencyKeyCannotMergeOrExposeAnotherEmployeesRequest() {
        UUID batchId = UUID.randomUUID();
        String key = UUID.randomUUID().toString();
        var request = new ProfileChangeDto.SubmitRequest(batchId,
                List.of(new ProfileChangeDto.FieldChange("fullName", "姓名", "原员工姓名")), key);
        var original = submissions(access).submit(request);
        var foreignAccess = accessFor(employeeB);
        var foreign = submissions(foreignAccess);
        assertThrows(ApiException.class, () -> foreign.submit(request));
        assertThrows(ApiException.class, () -> foreign.submit(new ProfileChangeDto.SubmitRequest(batchId,
                List.of(new ProfileChangeDto.FieldChange("seatNo", "座位", "外人修改"),
                        new ProfileChangeDto.FieldChange("fullName", "姓名", "外人姓名")), UUID.randomUUID().toString())));
        assertEquals(1, repository.findByBatchId(batchId).size());
        assertEquals(employeeA, repository.findById(original.requestIds().getFirst()).orElseThrow().getEmployeeId());
        assertNull(employees.findById(employeeB).orElseThrow().getSeatNo());
        assertEquals(0, employees.findById(employeeB).orElseThrow().getVersion());
    }

    @Test
    void clearedEncryptedDirectValueReplaysWithTheWritersNullSemantics() {
        var stored = new AtomicReference<String>("021-5555");
        when(applier.readCurrentValue(any(), eq("officePhone"))).thenAnswer(call -> stored.get());
        doAnswer(call -> { stored.set(ProfileFieldApplier.directWriteValue("officePhone", call.getArgument(2))); return null; })
                .when(applier).applyDirectEdit(any(), eq("officePhone"), anyString());
        var submit = submissions(access);
        UUID batchId = UUID.randomUUID();
        String key = UUID.randomUUID().toString();
        var request = new ProfileChangeDto.SubmitRequest(batchId, List.of(
                new ProfileChangeDto.FieldChange("officePhone", "办公电话", ""),
                new ProfileChangeDto.FieldChange("fullName", "姓名", "清空电话后姓名")), key);
        var receipt = submit.submit(request);
        entityManager.flush();
        assertNull(stored.get());
        assertEquals(receipt, submit.submit(request));
        assertEquals(1, employees.findById(employeeA).orElseThrow().getVersion());
        assertEquals(1, repository.findByBatchId(batchId).size());
        assertEquals(receipt, submit.submit(new ProfileChangeDto.SubmitRequest(batchId, List.of(
                new ProfileChangeDto.FieldChange("officePhone", "办公电话", "   "),
                new ProfileChangeDto.FieldChange("fullName", "姓名", "清空电话后姓名")), key)));
        assertEquals(" 021-5555 ", ProfileFieldApplier.directWriteValue("officePhone", " 021-5555 "), "非空内容不被trim");
        assertEquals("   ", ProfileFieldApplier.directWriteValue("seatNo", "   "), "普通字段保留原写入语义");
    }

    @Test
    void expandedIdempotencyColumnPreservesOldKeysAndAcceptsTheDeclaredFieldKeyBoundary() {
        assertEquals(193, jdbc.queryForObject("SELECT character_maximum_length FROM information_schema.columns WHERE table_schema='public' AND table_name='profile_change_requests' AND column_name='idem_key'", Integer.class));
        UUID oldRow = UUID.randomUUID();
        String oldKey = "L".repeat(64);
        jdbc.update("""
                INSERT INTO profile_change_requests(id,employee_id,batch_id,field_code,field_label,field_group,
                old_value_enc,new_value_enc,value_encoding,status,submitted_by,submitted_at,employee_version,idem_key)
                VALUES (?, ?, ?, 'fullName', '姓名', 'identity', 'old', 'new', 'PLAIN', 'rejected', ?, now(), 0, ?)
                """, oldRow, employeeA, UUID.randomUUID(), employeeA, oldKey);
        String relationship = "emergencyContact.0.relationship";
        String maximumField = "emergencyContact." + "0".repeat(34) + ".relationship";
        assertEquals(64, maximumField.length());
        assertEquals(0, ProfileFieldPolicy.emergencyContactIndex(maximumField));
        assertEquals("relationship", ProfileFieldPolicy.emergencyContactSubfield(maximumField));
        for (String field : List.of(relationship, maximumField)) {
            when(codec.encodingFor(field)).thenReturn("PGCRYPTO_V1");
            when(codec.encode(eq(field), nullable(String.class))).thenReturn("1:YWJjZGVmZ2g=");
        }
        var submit = submissions(access);
        String uuidKey = UUID.randomUUID().toString();
        var normal = submit.submit(new ProfileChangeDto.SubmitRequest(UUID.randomUUID(),
                List.of(new ProfileChangeDto.FieldChange(relationship, "关系", "同事")), uuidKey));
        String maximumKey = "M".repeat(128);
        var maximum = submit.submit(new ProfileChangeDto.SubmitRequest(UUID.randomUUID(),
                List.of(new ProfileChangeDto.FieldChange(maximumField, "关系", "家属")), maximumKey));
        entityManager.flush();
        assertEquals(uuidKey + ":" + relationship, repository.findById(normal.requestIds().getFirst()).orElseThrow().getIdemKey());
        assertEquals(193, repository.findById(maximum.requestIds().getFirst()).orElseThrow().getIdemKey().length());
        assertEquals(oldKey, jdbc.queryForObject("SELECT idem_key FROM profile_change_requests WHERE id=?", String.class, oldRow));
        jdbc.execute((org.springframework.jdbc.core.ConnectionCallback<Void>) connection -> {
            var savepoint = connection.setSavepoint();
            try (var duplicate = connection.prepareStatement("""
                    INSERT INTO profile_change_requests(employee_id,batch_id,field_code,field_label,field_group,
                    old_value_enc,new_value_enc,value_encoding,status,submitted_by,submitted_at,employee_version,idem_key)
                    SELECT employee_id,gen_random_uuid(),field_code,field_label,field_group,old_value_enc,new_value_enc,
                    value_encoding,status,submitted_by,submitted_at,employee_version,idem_key
                    FROM profile_change_requests WHERE id=?
                    """)) {
                duplicate.setObject(1, oldRow);
                var error = assertThrows(java.sql.SQLException.class, duplicate::executeUpdate);
                assertEquals("23505", error.getSQLState());
                connection.rollback(savepoint);
            } finally {
                connection.releaseSavepoint(savepoint);
            }
            return null;
        });
        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM profile_change_requests WHERE idem_key=?", Integer.class, oldKey));
    }

    @Test
    void concurrentApproveAndRejectHaveOnlyOneDecisionAndOneEmployeeVersionChange() throws Exception {
        AuthUser admin = mock(AuthUser.class);
        when(admin.getId()).thenReturn(UUID.randomUUID());
        when(access.requireHr()).thenReturn(admin);
        UUID[] fixture = {employeeA, batch(employeeA, "pending", 1, OffsetDateTime.now())};
        entityManager.flush();
        // Commit the owning fixture transaction before worker transactions.
        // Department/employee setup holds hierarchy/catalog locks too; opening
        // a REQUIRES_NEW fixture while the parent still holds those locks is
        // a self-blocking fixture, not evidence about the approval protocol.
        TestTransaction.flagForCommit();
        TestTransaction.end();
        CountDownLatch applied = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        doAnswer(call -> {
            applied.countDown();
            if (!release.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("test release timed out");
            return null;
        }).when(applier).applyReviewedChange(any(), any());
        var first = CompletableFuture.supplyAsync(() -> inNewTransaction(() -> {
            jdbc.execute("SELECT set_config('app.profile_change_snapshot_codec', 'v1', true)");
            return reviews.review(fixture[1], new ProfileChangeDto.ReviewAction("approve", null));
        }));
        try {
            assertTrue(applied.await(5, TimeUnit.SECONDS));
            CountDownLatch secondStarted = new CountDownLatch(1);
            var second = CompletableFuture.supplyAsync(() -> inNewTransaction(() -> {
                jdbc.execute("SELECT set_config('app.profile_change_snapshot_codec', 'v1', true)");
                secondStarted.countDown();
                try {
                    reviews.review(fixture[1], new ProfileChangeDto.ReviewAction("reject", "并发退回"));
                    return "decided";
                } catch (ApiException error) {
                    return error.getMessage();
                }
            }));
            assertTrue(secondStarted.await(5, TimeUnit.SECONDS));
            assertThrows(TimeoutException.class, () -> second.get(300, TimeUnit.MILLISECONDS), "另一审批必须等第一审批提交后重读");
            release.countDown();
            assertEquals("applied", first.get(5, TimeUnit.SECONDS).status());
            assertNotEquals("decided", second.get(5, TimeUnit.SECONDS));
            inNewTransaction(() -> {
                assertEquals("applied", repository.findByBatchId(fixture[1]).getFirst().getStatus());
                assertEquals(1, employees.findById(fixture[0]).orElseThrow().getVersion());
                return null;
            });
            verify(notices, times(1)).resolveProfileChangeBatch(fixture[1], "APPROVED");
            verify(notices, never()).resolveProfileChangeBatch(fixture[1], "REJECTED");
        } finally {
            release.countDown();
            first.get(5, TimeUnit.SECONDS);
            inNewTransaction(() -> {
                jdbc.execute("SELECT set_config('app.profile_change_snapshot_codec', 'v1', true)");
                jdbc.update("DELETE FROM profile_change_requests WHERE batch_id = ?", fixture[1]);
                jdbc.update("DELETE FROM employees WHERE id IN (?, ?)", employeeA, employeeB);
                jdbc.update("DELETE FROM departments WHERE id IN (?, ?)", departmentA, departmentB);
                return null;
            });
        }
    }

    private ProfileChangeSubmitService submissions(ProfileChangeAccess sourceAccess) {
        return new ProfileChangeSubmitService(repository, employees, applier, codec,
                sourceAccess, tx, notices, mock(StepUpService.class));
    }

    private ProfileChangeAccess accessFor(UUID employeeId) {
        var source = mock(ProfileChangeAccess.class);
        var actor = mock(AuthUser.class);
        when(actor.getEmployeeId()).thenReturn(employeeId);
        when(source.requireStaff()).thenReturn(actor);
        return source;
    }

    private <T> T inNewTransaction(java.util.function.Supplier<T> work) {
        TransactionTemplate template = new TransactionTemplate(transactionManager);
        template.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        return template.execute(ignored -> work.get());
    }

    private UUID department(String tag) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO departments(id, code, name, level, path) VALUES (?, ?, ?, '一级部门', '/')",
                id, "BATCH-D-" + id, "批次测试部门" + tag);
        return id;
    }

    private UUID employee(UUID department, String tag) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id, code, full_name, id_type, department_id, hire_date, status, employment_type)
                VALUES (?, ?, ?, '其他', ?, '2000-01-01', 'active', 'regular')
                """, id, "BATCH-E-" + id, "批次测试员工" + tag, department);
        return id;
    }

    private UUID batch(UUID employee, String status, int fields, OffsetDateTime at) {
        UUID batch = UUID.randomUUID();
        for (int i = 0; i < fields; i++) {
            UUID id = UUID.randomUUID();
            jdbc.update("""
                    INSERT INTO profile_change_requests(id, employee_id, batch_id, field_code, field_label, field_group,
                    old_value_enc, new_value_enc, value_encoding, status, submitted_by, submitted_at, employee_version, idem_key)
                    VALUES (?, ?, ?, ?, '测试字段', 'contact', 'old', 'new', 'PLAIN', ?, ?, ?, 0, ?)
                    """, id, employee, batch, "testField" + i, status, employee, at, id.toString());
        }
        return batch;
    }
}
