package com.uten.imp.features.org.employee.reconcile;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeCommandService;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSensitive;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.features.org.employee.reconcile.ReconcilePlanStore.ApplyRec;
import com.uten.imp.features.org.employee.reconcile.ReconcilePlanStore.ItemRec;
import com.uten.imp.features.org.employee.reconcile.ReconcilePlanStore.PlanRow;
import com.uten.imp.features.org.employee.reconcile.ReconcilePlanStore.RowRec;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcileApplyRequest;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcileApplyRequest.ItemSelection;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcileApplyRequest.RowSelection;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.ApplyCounts;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.ApplyItemResult;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.ApplyResult;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.ApplyRowResult;
import com.uten.imp.features.org.hrtask.HrTaskClaimService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentMatchers;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.SimpleTransactionStatus;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * ReconcileApplyService 单元测试：Store/命令服务/审计/加密全部 mock；TransactionTemplate 用
 * 真实对象 + mock PlatformTransactionManager 直接执行回调（照 AiJobWorkerTest 的先例）。
 * 密文即明文（加解密 mock 为恒等映射），让旧值守卫可以用肉眼可读的值断言。
 */
class ReconcileApplyServiceTest {

    /** IdRepairAdvisorTest 黄金用例同款有效号（校验码独立复核过）。 */
    private static final String VALID_F1 = "44200019900307123X";
    private static final String VALID_F2 = "450322198511122646";

    private final ReconcilePlanStore store = mock(ReconcilePlanStore.class);
    private final EmployeeRepository empRepo = mock(EmployeeRepository.class);
    private final EmployeeSensitiveRepository sensitiveRepo = mock(EmployeeSensitiveRepository.class);
    private final EmployeeCommandService employeeCommands = mock(EmployeeCommandService.class);
    private final HrTaskClaimService claimService = mock(HrTaskClaimService.class);
    private final AuditService audit = mock(AuditService.class);
    private final TxSessionVars tx = mock(TxSessionVars.class);
    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final ObjectMapper json = new ObjectMapper();
    private final PlatformTransactionManager transactions = mock(PlatformTransactionManager.class);
    private final ReconcileApplyService service = new ReconcileApplyService(
            store, empRepo, sensitiveRepo, employeeCommands, claimService, audit, tx, jdbc, json, transactions);

    private final UUID planId = UUID.randomUUID();
    private final UUID applyId = UUID.randomUUID();
    private final UUID actorId = UUID.randomUUID();
    private final UUID actorEmployeeId = UUID.randomUUID();
    private final UUID otherEmployeeId = UUID.randomUUID();
    private final UUID e1 = UUID.randomUUID();
    private final UUID e2 = UUID.randomUUID();
    private final AuthUser actor = new AuthUser(actorId, actorEmployeeId, "hr-test",
            Set.of("employee:view", "employee:edit", "employee:pii:edit"), false, true, false);

    private PlanRow plan;

    @BeforeEach
    void setUp() {
        when(transactions.getTransaction(any())).thenReturn(new SimpleTransactionStatus());
        // 密文即明文：批量解密返回恒等映射，单条解密 null 安全。
        when(tx.decryptAll(any())).thenAnswer(invocation -> {
            Collection<String> ciphers = invocation.getArgument(0);
            return ciphers.stream().collect(Collectors.toMap(cipher -> cipher, cipher -> cipher));
        });
        when(tx.tryDecrypt(any())).thenAnswer(invocation -> {
            String cipher = invocation.getArgument(0);
            return cipher == null || cipher.isBlank() ? Optional.empty() : Optional.of(cipher);
        });
        when(tx.encrypt(any())).thenAnswer(invocation -> "ENC:" + invocation.getArgument(0));
        // 轮次聚合与超管判定都返回 0（第 1 轮、无超管绑定）。
        when(jdbc.queryForObject(any(String.class), eq(Integer.class), any())).thenReturn(0);

        OffsetDateTime now = OffsetDateTime.now();
        plan = new PlanRow(planId, "ID_REPAIR", "PAGE", actorId, actorEmployeeId,
                "{\"rows\":2,\"update\":2}", "OPEN", null, 3, null,
                now.minusHours(1), now.plusHours(23), null, null);
        when(store.lockPlan(planId)).thenReturn(Optional.of(plan));
        when(store.findPlan(planId)).thenReturn(Optional.of(plan));
        when(store.renewApplyLease(planId, applyId)).thenReturn(true);
        when(store.findApplyByRequestId(planId, "req-1")).thenReturn(Optional.empty());
        when(store.insertApply(eq(planId), eq(1), eq("req-1"), eq(actorId))).thenReturn(
                new ApplyRec(applyId, 1, "req-1", "RUNNING", null, null, now, null));

        employee(e1, 7, "E-1");
        employee(e2, 9, "E-2");
        sensitive(e1, "OLD-1");
        sensitive(e2, "OLD-2");
        when(store.findRows(planId)).thenReturn(List.of(row(1, e1, 7), row(2, e2, 9)));
        when(store.findItems(planId)).thenReturn(List.of(
                item(1, "OLD-1", "NEW-1", candidateJson(VALID_F2)),
                item(2, "OLD-2", "NEW-2", candidateJson(VALID_F2))));
    }

    // ------------------------------------------------------------------
    // 重放 / 版本
    // ------------------------------------------------------------------

    @Test
    void finishedRequestIsReplayedFromStoredResultWithoutTouchingThePlan() throws Exception {
        ApplyResult stored = new ApplyResult(4, 2, new ApplyCounts(1, 1, 0),
                List.of(new ApplyRowResult(1, "APPLIED",
                        List.of(new ApplyItemResult(1, "APPLIED", null)))),
                "已更正 1 人 1 处，跳过 1 人（原因见结果列）");
        when(store.findApplyByRequestId(planId, "req-1")).thenReturn(Optional.of(new ApplyRec(
                applyId, 2, "req-1", "FINISHED", "{}", json.writeValueAsString(stored),
                OffsetDateTime.now(), OffsetDateTime.now())));

        assertThat(service.apply(actor, planId, request(rows(rowSelection(1))))).isEqualTo(stored);
        verify(store, never()).lockPlan(any());
        verify(store, never()).insertApply(any(), anyInt(), any(), any());
        verifyNoInteractions(employeeCommands, claimService);
    }

    @Test
    void runningRequestIsRejectedAsBusy() {
        when(store.findApplyByRequestId(planId, "req-1")).thenReturn(Optional.of(new ApplyRec(
                applyId, 1, "req-1", "RUNNING", null, null, OffsetDateTime.now(), null)));
        assertThatThrownBy(() -> service.apply(actor, planId, request(rows(rowSelection(1)))))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode().name()).isEqualTo("CONFLICT");
                    assertThat(error.getFieldErrors()).hasSize(1);
                    assertThat(error.getFieldErrors().getFirst().field()).isEqualTo("errorCode");
                    assertThat(error.getFieldErrors().getFirst().message()).isEqualTo("RECONCILE_PLAN_BUSY");
                });
        verify(store, never()).lockPlan(any());
    }

    @Test
    void anotherActorCannotReplayACompletedReceipt() {
        AuthUser other = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "other-hr",
                Set.of("employee:view", "employee:pii:edit"), false, true, false);
        assertThatThrownBy(() -> service.apply(other, planId, request(rows(rowSelection(1)))))
                .isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode()).isEqualTo(ErrorCode.NOT_FOUND));
        verify(store, never()).findApplyByRequestId(any(), any());
        verifyNoInteractions(employeeCommands);
    }

    @Test
    void reclaimedRoundCannotWriteEmployeesOrOverwriteItemOutcomes() {
        when(store.renewApplyLease(planId, applyId)).thenReturn(false);
        assertThatThrownBy(() -> service.apply(actor, planId, request(rows(rowSelection(1)))))
                .isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        verifyNoInteractions(employeeCommands);
        verify(store, never()).markRowResult(any(), anyInt(), any(), any());
        verify(store, never()).finishApply(any(), any(), any());
    }

    @Test
    void duplicateItemIsRejectedBeforeOpeningAnApplyRound() {
        RowSelection duplicated = new RowSelection(1, List.of(
                new ItemSelection(1, null, null), new ItemSelection(1, null, null)));
        assertThatThrownBy(() -> service.apply(actor, planId, request(rows(duplicated))))
                .isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        verify(store, never()).insertApply(any(), anyInt(), any(), any());
        verifyNoInteractions(employeeCommands);
    }

    @Test
    void stalePlanVersionIsRejectedAsChangedBeforeAnyWrite() {
        ReconcileApplyRequest stale = new ReconcileApplyRequest(2, "req-1", rows(rowSelection(1)));
        assertThatThrownBy(() -> service.apply(actor, planId, stale))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode().name()).isEqualTo("CONFLICT");
                    assertThat(error.getFieldErrors().getFirst().message())
                            .isEqualTo("RECONCILE_PLAN_CHANGED");
                });
        verify(store, never()).insertApply(any(), anyInt(), any(), any());
        verifyNoInteractions(employeeCommands);
    }

    @Test
    void applyingPlanRejectsAConcurrentRoundAsBusy() {
        OffsetDateTime now = OffsetDateTime.now();
        when(store.lockPlan(planId)).thenReturn(Optional.of(new PlanRow(planId, "ID_REPAIR", "PAGE",
                actorId, actorEmployeeId, "{}", "APPLYING", null, 3, now.plusMinutes(4),
                now.minusHours(1), now.plusHours(23), null, null)));
        assertThatThrownBy(() -> service.apply(actor, planId, request(rows(rowSelection(1)))))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getFieldErrors().getFirst().message())
                            .isEqualTo("RECONCILE_PLAN_BUSY");
                });
        verify(store, never()).insertApply(any(), anyInt(), any(), any());
        verifyNoInteractions(employeeCommands);
    }

    // ------------------------------------------------------------------
    // 守卫与失败隔离
    // ------------------------------------------------------------------

    @Test
    void staleStoredValueSkipsTheRowAndRecordsTheNotice() {
        sensitive(e1, "CHANGED-ELSEWHERE");
        ApplyResult result = service.apply(actor, planId, request(rows(rowSelection(1))));

        assertThat(result.counts().applied()).isZero();
        assertThat(result.counts().skipped()).isEqualTo(1);
        assertThat(result.rows().getFirst().result()).isEqualTo("SKIPPED");
        assertThat(result.rows().getFirst().items().getFirst().status()).isEqualTo("SKIPPED");
        verify(store).markItemOutcome(eq(planId), eq(1), eq(1), eq(applyId), eq("SKIPPED"),
                eq("STALE_VALUE"), any(), isNull(), isNull());
        verify(store).markRowResult(planId, 1, "SKIPPED", null);
        verify(employeeCommands, never()).changeIdentity(any(), any(), any());
        verify(store).finishApply(eq(applyId), contains("\"skipped\":1"), any());
    }

    @Test
    void changeIdentityConflictFailsThatRowAndStillAppliesTheNext() {
        doThrow(new ApiException(ErrorCode.CONFLICT, "该证件号已被其他员工使用"))
                .when(employeeCommands).changeIdentity(eq(e1), any(), any());
        ApplyResult result = service.apply(actor, planId, request(rows(rowSelection(1), rowSelection(2))));

        assertThat(result.counts().applied()).isEqualTo(1);
        assertThat(result.counts().failed()).isEqualTo(1);
        assertThat(result.rows().get(0).result()).isEqualTo("FAILED");
        assertThat(result.rows().get(0).items().getFirst().status()).isEqualTo("FAILED");
        assertThat(result.rows().get(0).items().getFirst().message()).contains("已被其他员工使用");
        assertThat(result.rows().get(1).result()).isEqualTo("APPLIED");
        verify(store).markItemOutcome(eq(planId), eq(1), eq(1), eq(applyId), eq("FAILED"),
                eq("CONFLICT"), eq("该证件号已被其他员工使用"), isNull(), isNull());
        verify(store).markRowResult(planId, 1, "FAILED", null);
        verify(store).markRowResult(eq(planId), eq(2), eq("APPLIED"), any());
        verify(employeeCommands).changeIdentity(eq(e2), eq("身份证"), eq("NEW-2"));
        verify(audit).logCommittedChange(eq(actorId), eq("hr-test"), eq("employee_reconcile.apply"),
                eq("employees"), eq(e2.toString()), eq("已更正证件号码"), any());
    }

    // ------------------------------------------------------------------
    // appliedOrigin 三态
    // ------------------------------------------------------------------

    @Test
    void appliedOriginFollowsManualInputCandidateChoiceAndSuggestion() {
        // 三行都指向同一批员工夹具（e1/e1/e2），互不干扰：行 1 手输、行 2 改选候选、行 3 用建议值。
        when(store.findRows(planId)).thenReturn(List.of(row(1, e1, 7), row(2, e1, 7), row(3, e2, 9)));
        when(store.findItems(planId)).thenReturn(List.of(
                item(1, "OLD-1", "NEW-1", candidateJson(VALID_F2)),
                item(2, "OLD-1", "NEW-1", candidateJson(VALID_F2)),
                item(3, "OLD-2", "NEW-2", candidateJson(VALID_F2))));

        ApplyResult result = service.apply(actor, planId, request(rows(
                new RowSelection(1, List.of(new ItemSelection(1, null, VALID_F1))),
                new RowSelection(2, List.of(new ItemSelection(1, 0, null))),
                new RowSelection(3, List.of(new ItemSelection(1, null, null))))));

        assertThat(result.counts().applied()).isEqualTo(3);
        // 手输 → EDITED（最终值密文回写为规范化后的手输值）
        verify(store).markItemOutcome(eq(planId), eq(1), eq(1), eq(applyId), eq("APPLIED"),
                isNull(), isNull(), eq("EDITED"), eq("ENC:" + VALID_F1));
        // 改选候选 → CANDIDATE（回写候选值密文）
        verify(store).markItemOutcome(eq(planId), eq(2), eq(1), eq(applyId), eq("APPLIED"),
                isNull(), isNull(), eq("CANDIDATE"), eq("ENC:" + VALID_F2));
        // 都没给 → SUGGESTED（沿用建议值密文，不覆盖）
        verify(store).markItemOutcome(eq(planId), eq(3), eq(1), eq(applyId), eq("APPLIED"),
                isNull(), isNull(), eq("SUGGESTED"), isNull());
        verify(employeeCommands).changeIdentity(e1, "身份证", VALID_F1);
        verify(employeeCommands).changeIdentity(e1, "身份证", VALID_F2);
        verify(employeeCommands).changeIdentity(e2, "身份证", "NEW-2");
    }

    // ------------------------------------------------------------------
    // 认领
    // ------------------------------------------------------------------

    @Test
    void foreignClaimSkipsTheRowAndOwnClaimIsReleasedAfterSuccess() {
        // e1 被他人认领 → 整行 SKIPPED(CLAIMED_BY_OTHER)；e2 是本人认领 → 更正成功后释放。
        stubClaims(Map.of(e1, otherEmployeeId, e2, actorEmployeeId));

        ApplyResult result = service.apply(actor, planId, request(rows(rowSelection(1), rowSelection(2))));

        assertThat(result.counts().skipped()).isEqualTo(1);
        assertThat(result.counts().applied()).isEqualTo(1);
        verify(store).markItemOutcome(eq(planId), eq(1), eq(1), eq(applyId), eq("SKIPPED"),
                eq("CLAIMED_BY_OTHER"), contains("处理"), isNull(), isNull());
        verify(employeeCommands, never()).changeIdentity(eq(e1), any(), any());
        verify(claimService, never()).release(any(), eq(e1));
        verify(claimService).release("identity", e2);
    }

    @Test
    void ownClaimDoesNotBlockTheRow() {
        stubClaims(Map.of(e1, actorEmployeeId));
        ApplyResult result = service.apply(actor, planId, request(rows(rowSelection(1))));
        assertThat(result.counts().applied()).isEqualTo(1);
        verify(claimService).release("identity", e1);
    }

    // ------------------------------------------------------------------
    // 整体校验
    // ------------------------------------------------------------------

    @Test
    void invalidManualValueFailsTheWholeRequestBeforeAnyWrite() {
        ReconcileApplyRequest invalid = new ReconcileApplyRequest(3, "req-1",
                rows(new RowSelection(1, List.of(new ItemSelection(1, null, "44200019900307")))));
        assertThatThrownBy(() -> service.apply(actor, planId, invalid))
                .isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode().name()).isEqualTo("VALIDATION_FAILED"));
        verify(store, never()).insertApply(any(), anyInt(), any(), any());
        verifyNoInteractions(employeeCommands);
    }

    @Test
    void candidateIndexBeyondAvailableCandidatesFailsValidation() {
        ReconcileApplyRequest invalid = new ReconcileApplyRequest(3, "req-1",
                rows(new RowSelection(1, List.of(new ItemSelection(1, 5, null)))));
        assertThatThrownBy(() -> service.apply(actor, planId, invalid))
                .isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode().name()).isEqualTo("VALIDATION_FAILED"));
        verify(store, never()).markItemOutcome(any(), anyInt(), anyInt(), any(), any(), any(), any(), any(), any());
    }

    @Test
    void summaryDescribesSkippedAndFailedRowsWithoutAppliedPart() {
        doThrow(new ApiException(ErrorCode.CONFLICT, "该证件号已被其他员工使用"))
                .when(employeeCommands).changeIdentity(eq(e1), any(), any());
        sensitive(e2, "CHANGED");
        ApplyResult result = service.apply(actor, planId, request(rows(rowSelection(1), rowSelection(2))));
        assertThat(result.counts().applied()).isZero();
        assertThat(result.counts().skipped()).isEqualTo(1);
        assertThat(result.counts().failed()).isEqualTo(1);
        assertThat(result.summary()).isEqualTo("跳过 1 人（原因见结果列），失败 1 人（原因见结果列）");
        assertThat(result.planVersion()).isEqualTo(4);
        assertThat(result.round()).isEqualTo(1);
    }

    // ------------------------------------------------------------------
    // 夹具
    // ------------------------------------------------------------------

    /** 认领查询桩：employeeId → 认领人（jdbc.query 的 varargs 兼容展开与折叠两种形态）。 */
    private void stubClaims(Map<UUID, UUID> claimsByEmployee) {
        when(jdbc.query(any(String.class), ArgumentMatchers.<RowMapper<ReconcilePlanQueryService.ActiveClaim>>any(),
                any(Object[].class))).thenAnswer(invocation -> {
            Object last = invocation.getArguments()[invocation.getArguments().length - 1];
            Object employeeId = last instanceof Object[] array ? array[array.length - 1] : last;
            UUID claimedBy = claimsByEmployee.get(employeeId);
            if (claimedBy == null) {
                return List.of();
            }
            return List.of(new ReconcilePlanQueryService.ActiveClaim(
                    (UUID) employeeId, claimedBy, OffsetDateTime.now().plusMinutes(30)));
        });
    }

    private static ReconcileApplyRequest request(List<RowSelection> selections) {
        return new ReconcileApplyRequest(3, "req-1", selections);
    }

    private static List<RowSelection> rows(RowSelection... selections) {
        return List.of(selections);
    }

    private static RowSelection rowSelection(int rowNo) {
        return new RowSelection(rowNo, List.of(new ItemSelection(1, null, null)));
    }

    private static RowRec row(int rowNo, UUID employeeId, int version) {
        return new RowRec(rowNo, employeeId, version, "UPDATE", List.of(), null);
    }

    private static ItemRec item(int rowNo, String oldValue, String newValue, String candidatesJson) {
        return new ItemRec(rowNo, 1, "idNumber", "CHANGE_IDENTITY", oldValue, newValue,
                candidatesJson, List.of(3), List.of(), "CHECK_SOLVED", "MEDIUM",
                BigDecimal.valueOf(0.9), false, List.of(), null, null, null, null, null, null);
    }

    private static String candidateJson(String value) {
        return "[{\"value\":\"" + value + "\",\"probability\":0.9,\"diffPositions\":[3]}]";
    }

    private void employee(UUID id, int version, String code) {
        Employee employee = new Employee();
        employee.setId(id);
        employee.setCode(code);
        employee.setFullName("员工" + code);
        employee.setStatus("active");
        employee.setVersion(version);
        when(empRepo.findById(id)).thenReturn(Optional.of(employee));
        when(empRepo.findByIdForUpdate(id)).thenReturn(Optional.of(employee));
    }

    private void sensitive(UUID employeeId, String idCardEnc) {
        EmployeeSensitive sensitive = new EmployeeSensitive();
        sensitive.setEmployeeId(employeeId);
        sensitive.setIdCardEnc(idCardEnc);
        when(sensitiveRepo.findByEmployeeId(employeeId)).thenReturn(Optional.of(sensitive));
    }
}
