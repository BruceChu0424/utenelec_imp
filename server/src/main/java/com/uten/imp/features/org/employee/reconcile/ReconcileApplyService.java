package com.uten.imp.features.org.employee.reconcile;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeCommandService;
import com.uten.imp.features.org.employee.EmployeeIdentityCheck;
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
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.CandidateView;
import com.uten.imp.features.org.hrtask.HrTaskClaimService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import lombok.extern.slf4j.Slf4j;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * 执行一轮核对更正（V810/ADR-160）：重放（同 request_id 幂等）→ 锁定事务整体校验并登记回执 →
 * 逐人 REQUIRES_NEW 调既有 {@link EmployeeCommandService#changeIdentity} → 收尾回执（计划回 OPEN、
 * 版本 +1）。中途崩溃由 {@link ReconcilePlanHousekeeping} 按 applying_until 租约回收兜底。
 *
 * <p>本类不加类级事务：每一步都是显式的短事务（照 AiChatActionProposalService 的
 * TransactionTemplate 构造器模式）。失败标记写在独立的补写事务里——changeIdentity 参与同一
 * 事务时一旦抛错，事务已被内层 {@code @Transactional} 置为 rollback-only，在同一事务里再写
 * FAILED 标记会在提交时翻车（UnexpectedRollbackException）。</p>
 */
@Slf4j
@Service
public class ReconcileApplyService {

    private static final Set<String> IN_SCOPE_STATUSES = Set.of("active", "probation");
    private static final int OUTCOME_MESSAGE_MAX = 240;

    private final ReconcilePlanStore store;
    private final EmployeeRepository empRepo;
    private final EmployeeSensitiveRepository sensitiveRepo;
    private final EmployeeCommandService employeeCommands;
    private final HrTaskClaimService claimService;
    private final AuditService audit;
    private final TxSessionVars tx;
    private final JdbcTemplate jdbc;
    private final ObjectMapper json;
    private final TransactionTemplate newTx;

    public ReconcileApplyService(ReconcilePlanStore store,
                                 EmployeeRepository empRepo,
                                 EmployeeSensitiveRepository sensitiveRepo,
                                 EmployeeCommandService employeeCommands,
                                 HrTaskClaimService claimService,
                                 AuditService audit,
                                 TxSessionVars tx,
                                 JdbcTemplate jdbc,
                                 ObjectMapper json,
                                 PlatformTransactionManager transactions) {
        this.store = store;
        this.empRepo = empRepo;
        this.sensitiveRepo = sensitiveRepo;
        this.employeeCommands = employeeCommands;
        this.claimService = claimService;
        this.audit = audit;
        this.tx = tx;
        this.jdbc = jdbc;
        this.json = json;
        this.newTx = new TransactionTemplate(transactions);
        this.newTx.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.newTx.setTimeout(30);
    }

    public ApplyResult apply(AuthUser actor, UUID planId, ReconcileApplyRequest request) {
        // 幂等回执与首次执行使用同一个属主边界，知道 requestId 不能越权读取结果。
        PlanRow visiblePlan = store.findPlan(planId).orElseThrow(ReconcilePlanQueryService::notFound);
        if (!actor.getId().equals(visiblePlan.actorUserId())) {
            throw ReconcilePlanQueryService.notFound();
        }
        // 1. 重放：同请求幂等（无锁读）。
        Optional<ApplyRec> replay = store.findApplyByRequestId(planId, request.requestId());
        if (replay.isPresent()) {
            ApplyRec receipt = replay.get();
            if ("FINISHED".equals(receipt.status())) {
                return readResult(receipt.resultJson());
            }
            if ("RUNNING".equals(receipt.status())) {
                throw conflict("RECONCILE_PLAN_BUSY", "这个核对正在执行更正，请稍后刷新查看结果");
            }
            throw conflict("RECONCILE_PLAN_CHANGED", "上一轮更正被中断，请刷新核对结果后重新提交");
        }

        // 2. 锁定事务：整体校验 + 登记回执 + 计划置 APPLYING（5 分钟租约）。
        BeginOutcome begun = newTx.execute(status -> begin(actor, planId, request));
        if (begun.reject() != null) {
            throw begun.reject();
        }

        // 3. 逐人执行（选中且校验通过的行，按 rowNo 升序），一人失败继续下一人。
        List<ApplyRowResult> rowResults = new ArrayList<>(begun.rows().size());
        int applied = 0;
        int skipped = 0;
        int failed = 0;
        int appliedItems = 0;
        for (PreparedRow row : begun.rows()) {
            RowOutcome outcome = executeRow(actor, planId, begun.apply(), row);
            rowResults.add(new ApplyRowResult(row.row().rowNo(), outcome.result(),
                    outcome.items()));
            switch (outcome.result()) {
                case "APPLIED" -> {
                    applied++;
                    appliedItems += outcome.items().size();
                }
                case "SKIPPED" -> skipped++;
                default -> failed++;
            }
        }

        // 4. 收尾：回执 FINISHED + 计划回 OPEN、版本 +1。
        ApplyResult result = new ApplyResult(
                begun.plan().version() + 1, begun.apply().roundNo(),
                new ApplyCounts(applied, skipped, failed), rowResults,
                summary(applied, appliedItems, skipped, failed));
        String countsJson = writeJson(Map.of("applied", applied, "skipped", skipped, "failed", failed));
        String resultJson = writeJson(result);
        newTx.executeWithoutResult(status -> {
            requireActiveApply(planId, begun.apply());
            store.finishApply(begun.apply().id(), countsJson, resultJson);
        });
        return result;
    }

    // ------------------------------------------------------------------
    // 第 2 步：锁定事务（整体校验，任何写都不发生）
    // ------------------------------------------------------------------

    private BeginOutcome begin(AuthUser actor, UUID planId, ReconcileApplyRequest request) {
        PlanRow plan = store.lockPlan(planId).orElseThrow(ReconcilePlanQueryService::notFound);
        if (!actor.getId().equals(plan.actorUserId())) {
            throw ReconcilePlanQueryService.notFound();
        }
        if ("CLOSED".equals(plan.status())) {
            throw conflict("EXPIRED".equals(plan.closedReason()) ? "RECONCILE_PLAN_EXPIRED"
                    : "RECONCILE_PLAN_CHANGED",
                    "EXPIRED".equals(plan.closedReason()) ? "核对计划已过期，请重新生成"
                            : "核对计划已关闭");
        }
        if ("APPLYING".equals(plan.status())) {
            // 并发的第二轮更正：租约(applying_until)未超时就排队拒绝，超时的由 Housekeeping 回收。
            throw conflict("RECONCILE_PLAN_BUSY", "这个核对正在执行更正，请稍后刷新查看结果");
        }
        if (plan.version() != request.planVersion()) {
            throw conflict("RECONCILE_PLAN_CHANGED", "核对计划已变化，请刷新后重试");
        }
        if (plan.expiresAt() == null || !plan.expiresAt().isAfter(java.time.OffsetDateTime.now())) {
            // 先关闭再返回冲突：closePlan 已随本事务提交（不走抛错回滚路径）。
            store.closePlan(planId, "EXPIRED");
            return new BeginOutcome(null, null, plan,
                    conflict("RECONCILE_PLAN_EXPIRED", "核对计划已过期，请重新生成"));
        }
        List<PreparedRow> rows = validateAndPrepare(planId, request);
        ApplyRec apply = store.insertApply(planId, nextRoundNo(planId),
                request.requestId(), actor.getId());
        markApplying(planId);
        return new BeginOutcome(apply, rows, plan, null);
    }

    /** 全量校验（行号/项号存在、候选不越界、手输值过校验、最终值可得），不合法直接 422。 */
    private List<PreparedRow> validateAndPrepare(UUID planId, ReconcileApplyRequest request) {
        List<RowRec> rows = store.findRows(planId);
        List<ItemRec> items = store.findItems(planId);
        Map<Integer, RowRec> rowsByNo = new LinkedHashMap<>();
        rows.forEach(row -> rowsByNo.put(row.rowNo(), row));
        Map<Integer, List<ItemRec>> itemsByRow = new LinkedHashMap<>();
        items.forEach(item -> itemsByRow
                .computeIfAbsent(item.rowNo(), key -> new ArrayList<>()).add(item));

        List<String> ciphers = new ArrayList<>();
        items.forEach(item -> {
            addCipher(ciphers, item.newValueEnc());
            addCipher(ciphers, item.candidatesEnc());
        });
        Map<String, String> plain = ReconcilePlanQueryService.decryptQuietly(tx, ciphers);

        Set<Integer> seenRows = new LinkedHashSet<>();
        List<PreparedRow> prepared = new ArrayList<>(request.rows().size());
        for (RowSelection selection : request.rows()) {
            int rowNo = selection.rowNo();
            if (!seenRows.add(rowNo)) {
                throw invalid("核对请求里第 " + rowNo + " 行重复提交");
            }
            RowRec row = rowsByNo.get(rowNo);
            if (row == null) {
                throw invalid("核对计划里没有第 " + rowNo + " 行");
            }
            List<PreparedItem> preparedItems = new ArrayList<>(selection.items().size());
            Set<Integer> seenItems = new LinkedHashSet<>();
            for (ItemSelection itemSelection : selection.items()) {
                if (!seenItems.add(itemSelection.itemNo())) {
                    throw invalid("第 " + rowNo + " 行的更正项重复提交");
                }
                ItemRec item = itemsByRow.getOrDefault(rowNo, List.of()).stream()
                        .filter(candidate -> candidate.itemNo() == itemSelection.itemNo())
                        .findFirst().orElse(null);
                if (item == null) {
                    throw invalid("第 " + rowNo + " 行没有第 " + itemSelection.itemNo() + " 项");
                }
                if ("APPLIED".equals(item.outcome())) {
                    throw invalid("第 " + rowNo + " 行已更正，请刷新核对结果");
                }
                List<CandidateView> candidates = parseCandidates(candidatesJsonOf(plain, item.candidatesEnc()));
                if (itemSelection.candidateIndex() != null
                        && (itemSelection.candidateIndex() >= candidates.size())) {
                    throw invalid("第 " + rowNo + " 行第 " + itemSelection.itemNo()
                            + " 项的候选序号超出范围");
                }
                String manual = blankToNull(itemSelection.value());
                if (manual != null && IdCardUtil.check(manual) != null) {
                    throw invalid("第 " + rowNo + " 行手输的证件号未通过校验："
                            + IdCardUtil.check(manual).message());
                }
                String suggested = blankToNull(suggestedJsonOf(plain, item.newValueEnc()));
                if (manual == null && itemSelection.candidateIndex() == null && suggested == null) {
                    throw invalid("第 " + rowNo + " 行第 " + itemSelection.itemNo()
                            + " 项没有可执行的更正值，请选择候选或输入新证件号");
                }
                preparedItems.add(new PreparedItem(item, itemSelection, candidates, suggested));
            }
            prepared.add(new PreparedRow(row, preparedItems));
        }
        prepared.sort(java.util.Comparator.comparing(row -> row.row().rowNo()));
        return prepared;
    }

    private int nextRoundNo(UUID planId) {
        // ReconcilePlanStore 未提供轮次查询；只读一条聚合，参数化，与 insertApply 同在锁定事务内。
        Integer current = jdbc.queryForObject(
                "SELECT COALESCE(MAX(round_no), 0) FROM employee_reconcile_applies WHERE plan_id = ?",
                Integer.class, planId);
        return current == null ? 1 : current + 1;
    }

    private void markApplying(UUID planId) {
        // ReconcilePlanStore 没有「置 APPLYING」方法且本次不改该类；与 insertApply 同一锁定事务，
        // 参数化 UPDATE 一条（ck_erp_applying 成对约束由数据库兜底）。租约 5 分钟，超时由
        // ReconcilePlanHousekeeping.reclaimStaleApplying 回收。
        jdbc.update("""
                UPDATE employee_reconcile_plans SET status = 'APPLYING',
                       applying_until = now() + interval '5 minutes'
                WHERE id = ? AND status = 'OPEN'
                """, planId);
    }

    // ------------------------------------------------------------------
    // 第 3 步：逐人 REQUIRES_NEW 执行
    // ------------------------------------------------------------------

    private RowOutcome executeRow(AuthUser actor, UUID planId, ApplyRec apply, PreparedRow row) {
        try {
            newTx.executeWithoutResult(status -> {
                requireActiveApply(planId, apply);
                doApplyRow(actor, planId, apply, row);
            });
            List<ApplyItemResult> items = row.items().stream()
                    .map(item -> new ApplyItemResult(item.item().itemNo(), "APPLIED", null))
                    .toList();
            return new RowOutcome("APPLIED", items);
        } catch (ApplyLeaseLost lost) {
            throw lost;
        } catch (RowSkipped skipped) {
            recordOutcome(planId, apply, row, "SKIPPED", skipped.code(), skipped.getMessage());
            return outcomeView(row, "SKIPPED", skipped.getMessage());
        } catch (AccessDeniedException | ApiException failure) {
            String code = failure instanceof ApiException apiException
                    ? apiException.getCode().name() : "FORBIDDEN";
            String message = truncate(failure.getMessage());
            log.warn("员工资料核对更正第 {} 行被拒绝: {}: {}", row.row().rowNo(), code, message);
            recordOutcome(planId, apply, row, "FAILED", code, message);
            return outcomeView(row, "FAILED", message);
        } catch (RuntimeException failure) {
            log.warn("员工资料核对更正第 {} 行失败", row.row().rowNo(), failure);
            recordOutcome(planId, apply, row, "FAILED", "INTERNAL", "系统错误");
            return outcomeView(row, "FAILED", "系统错误");
        }
    }

    private void doApplyRow(AuthUser actor, UUID planId, ApplyRec apply, PreparedRow row) {
        UUID employeeId = row.row().employeeId();
        // 先锁员工再读取版本和旧值；与单人证件修改共享这把锁，不能检查后被并发覆盖。
        Employee employee = empRepo.findByIdForUpdate(employeeId)
                .filter(candidate -> !candidate.isDeleted())
                .orElse(null);
        if (employee == null || !IN_SCOPE_STATUSES.contains(employee.getStatus())) {
            throw new RowSkipped(null, "员工已不在职或已删除");
        }
        if (superAdminBound(employeeId)) {
            throw new RowSkipped(ReconcileNotice.SUPER_ADMIN_BOUND.code(),
                    ReconcileNotice.SUPER_ADMIN_BOUND.message());
        }
        ReconcilePlanQueryService.ActiveClaim claim = activeClaim(employeeId);
        UUID me = actor.getEmployeeId();
        if (claim != null && (me == null || !claim.claimedBy().equals(me))) {
            throw new RowSkipped(ReconcileNotice.CLAIMED_BY_OTHER.code(),
                    ReconcilePlanQueryService.claimedByOtherMessage(
                            claimantName(claim.claimedBy()), claim));
        }
        if (employee.getVersion() != row.row().employeeVersion()) {
            throw new RowSkipped(ReconcileNotice.STALE_VERSION.code(),
                    ReconcileNotice.STALE_VERSION.message());
        }
        if (!ReconcilePlanQueryService.canEditPii(actor)) {
            throw new RowSkipped(ReconcileNotice.NO_PERMISSION.code(),
                    ReconcileNotice.NO_PERMISSION.message());
        }
        String current = currentIdNumber(employeeId);

        for (PreparedItem item : row.items()) {
            String oldValue = blankToNull(plainOf(item.item().oldValueEnc()));
            String normalizedOld = oldValue == null ? null : IdCardUtil.normalize(oldValue);
            if (!Objects.equals(current, normalizedOld)) {
                throw new RowSkipped(ReconcileNotice.STALE_VALUE.code(),
                        ReconcileNotice.STALE_VALUE.message());
            }
            String finalValue = finalValue(item);
            employeeCommands.changeIdentity(employeeId,
                    EmployeeIdentityCheck.RESIDENT_ID, finalValue);
            String origin = appliedOrigin(item.selection());
            // SUGGESTED 时 new_value_enc 已是建议值密文，不覆盖；手输/改选候选回写实际执行值。
            String finalValueEnc = "SUGGESTED".equals(origin)
                    ? null : tx.encrypt(IdCardUtil.normalize(finalValue));
            store.markItemOutcome(planId, row.row().rowNo(), item.item().itemNo(), apply.id(),
                    "APPLIED", null, null, origin, finalValueEnc);
        }

        // 成功路径同事务收尾：回写行结果（读回 employees.version）+ 审计 + 释放本人认领。
        Integer newVersion = empRepo.findById(employeeId).map(Employee::getVersion).orElse(null);
        store.markRowResult(planId, row.row().rowNo(), "APPLIED", newVersion);
        audit.logCommittedChange(actor.getId(), actor.getLoginAccount(),
                "employee_reconcile.apply", "employees", employeeId.toString(), "已更正证件号码",
                applyChange(planId, apply, row));
        if (claim != null && me != null && claim.claimedBy().equals(me)) {
            try {
                // HrTaskClaimService.IDENTITY_TASK_TYPE 包私有，这里用同值字面量；本人释放幂等。
                claimService.release(ReconcilePlanQueryService.IDENTITY_TASK_TYPE, employeeId);
            } catch (RuntimeException releaseFailed) {
                log.warn("核对更正后释放本人认领失败（不影响更正结果）: employeeId={}", employeeId,
                        releaseFailed);
            }
        }
    }

    private Map<String, Object> applyChange(UUID planId, ApplyRec apply, PreparedRow row) {
        String basis = row.items().isEmpty() ? "" : row.items().getFirst().item().basisCode();
        Map<String, Object> field = new LinkedHashMap<>();
        field.put("field", "idNumber");
        field.put("changed", true);
        field.put("basis", basis == null ? "" : basis);
        Map<String, Object> change = new LinkedHashMap<>();
        change.put("planId", planId.toString());
        change.put("round", apply.roundNo());
        change.put("fields", List.of(field));
        return change;
    }

    /** 补写事务：跳过/失败的行结果（原事务已回滚或 rollback-only，不能复用）。 */
    private void recordOutcome(UUID planId, ApplyRec apply, PreparedRow row,
                               String outcome, String code, String message) {
        newTx.executeWithoutResult(status -> {
            requireActiveApply(planId, apply);
            for (PreparedItem item : row.items()) {
                store.markItemOutcome(planId, row.row().rowNo(), item.item().itemNo(), apply.id(),
                        outcome, code, truncate(message), null, null);
            }
            store.markRowResult(planId, row.row().rowNo(), outcome, null);
        });
    }

    private void requireActiveApply(UUID planId, ApplyRec apply) {
        if (!store.renewApplyLease(planId, apply.id())) {
            throw new ApplyLeaseLost();
        }
    }

    private static final class ApplyLeaseLost extends ApiException {
        ApplyLeaseLost() {
            super(ErrorCode.CONFLICT, "核对执行已过期或被回收，请刷新后查看已完成结果",
                    List.of(new ApiError.FieldError("errorCode", "RECONCILE_PLAN_CHANGED")));
        }
    }

    private static RowOutcome outcomeView(PreparedRow row, String outcome, String message) {
        List<ApplyItemResult> items = row.items().stream()
                .map(item -> new ApplyItemResult(item.item().itemNo(), outcome, truncate(message)))
                .toList();
        return new RowOutcome(outcome, items);
    }

    private static String appliedOrigin(ItemSelection selection) {
        if (blankToNull(selection.value()) != null) {
            return "EDITED";
        }
        return selection.candidateIndex() != null ? "CANDIDATE" : "SUGGESTED";
    }

    private static String finalValue(PreparedItem item) {
        String manual = blankToNull(item.selection().value());
        if (manual != null) {
            return manual;
        }
        if (item.selection().candidateIndex() != null
                && item.selection().candidateIndex() < item.candidates().size()) {
            return item.candidates().get(item.selection().candidateIndex()).value();
        }
        return item.suggestedValue();
    }

    private String currentIdNumber(UUID employeeId) {
        String cipher = sensitiveRepo.findByEmployeeId(employeeId)
                .map(EmployeeSensitive::getIdCardEnc)
                .orElse(null);
        return tx.tryDecrypt(cipher).map(IdCardUtil::normalize).orElse(null);
    }

    private String plainOf(String cipher) {
        if (cipher == null || cipher.isBlank()) {
            return null;
        }
        return tx.tryDecrypt(cipher).orElse(null);
    }

    private List<CandidateView> parseCandidates(String candidatesJson) {
        if (candidatesJson == null || candidatesJson.isBlank()) {
            return List.of();
        }
        try {
            List<CandidateView> parsed = json.readValue(candidatesJson,
                    new com.fasterxml.jackson.core.type.TypeReference<List<CandidateView>>() {
                    });
            return parsed == null ? List.of() : parsed;
        } catch (Exception unreadable) {
            return List.of();
        }
    }

    private boolean superAdminBound(UUID employeeId) {
        // 与 EmployeeCommandService.changeIdentity 的超管判定同口径 (不过滤已删账号，宁可多拦)。
        // EXISTS 在 PostgreSQL 里是 boolean，按 Integer 取值会报「不良的类型值 int : f」。
        Boolean bound = jdbc.queryForObject(
                "SELECT EXISTS (SELECT 1 FROM users WHERE employee_id = ? AND is_super_admin)",
                Boolean.class, employeeId);
        return Boolean.TRUE.equals(bound);
    }

    private ReconcilePlanQueryService.ActiveClaim activeClaim(UUID employeeId) {
        List<ReconcilePlanQueryService.ActiveClaim> claims = jdbc.query("""
                SELECT employee_id, claimed_by, lease_until FROM hr_task_claims
                WHERE task_type = ? AND employee_id = ? AND released_at IS NULL
                  AND lease_until > now()
                LIMIT 1
                """, (rs, i) -> new ReconcilePlanQueryService.ActiveClaim(
                rs.getObject("employee_id", UUID.class),
                rs.getObject("claimed_by", UUID.class),
                rs.getObject("lease_until", java.time.OffsetDateTime.class)),
                ReconcilePlanQueryService.IDENTITY_TASK_TYPE, employeeId);
        return claims.isEmpty() ? null : claims.getFirst();
    }

    private String claimantName(UUID claimedBy) {
        return empRepo.findById(claimedBy).map(Employee::getFullName).orElse("同事");
    }

    private ApplyResult readResult(String resultJson) {
        if (resultJson == null || resultJson.isBlank()) {
            throw new IllegalStateException("更正回执缺少结果，请核对执行记录");
        }
        try {
            return json.readValue(resultJson, ApplyResult.class);
        } catch (Exception unreadable) {
            throw new IllegalStateException("更正回执结果无法读取", unreadable);
        }
    }

    private String writeJson(Object value) {
        try {
            return json.writeValueAsString(value);
        } catch (Exception failure) {
            throw new IllegalStateException("更正回执 JSON 序列化失败", failure);
        }
    }

    /** 结果摘要（不含 6 位以上连续数字，满足 applies.result 的库 CHECK）。 */
    private static String summary(int appliedRows, int appliedItems, int skipped, int failed) {
        StringBuilder text = new StringBuilder();
        if (appliedRows > 0) {
            text.append("已更正 ").append(appliedRows).append(" 人 ").append(appliedItems).append(" 处");
        }
        if (skipped > 0) {
            if (!text.isEmpty()) {
                text.append("，");
            }
            text.append("跳过 ").append(skipped).append(" 人（原因见结果列）");
        }
        if (failed > 0) {
            if (!text.isEmpty()) {
                text.append("，");
            }
            text.append("失败 ").append(failed).append(" 人（原因见结果列）");
        }
        return text.isEmpty() ? "本轮没有可执行的更正" : text.toString();
    }

    private static String truncate(String message) {
        if (message == null) {
            return null;
        }
        String bounded = message.length() <= OUTCOME_MESSAGE_MAX ? message
                : message.substring(0, OUTCOME_MESSAGE_MAX);
        // 库约束禁止 6 位以上连续数字（防止结果里夹带证件号）；异常消息里的长数字串打码。
        return bounded.replaceAll("[0-9]{6,}", "******");
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }

    private static void addCipher(List<String> ciphers, String cipher) {
        if (cipher != null && !cipher.isBlank()) {
            ciphers.add(cipher);
        }
    }

    /** 候选密文为空 (无候选档位) 时返回 null；批量解密结果是不可变 Map，不接受 null 键。 */
    private static String candidatesJsonOf(Map<String, String> plain, String cipher) {
        return cipher == null ? null : plain.get(cipher);
    }

    /** 建议值密文为空 (无候选档位) 时返回 null；批量解密结果是不变 Map，不接受 null 键。 */
    private static String suggestedJsonOf(Map<String, String> plain, String cipher) {
        return cipher == null ? null : plain.get(cipher);
    }

    static ApiException conflict(String code, String message) {
        return new ApiException(ErrorCode.CONFLICT, message,
                List.of(new ApiError.FieldError("errorCode", code)));
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    /** 事务里主动放弃的行（守卫未通过）：事务内还没有任何写，回滚即无痕。 */
    private static final class RowSkipped extends RuntimeException {
        private final String code;

        RowSkipped(String code, String message) {
            super(message);
            this.code = code;
        }

        String code() {
            return code;
        }
    }

    private record BeginOutcome(ApplyRec apply, List<PreparedRow> rows, PlanRow plan,
                                ApiException reject) {
    }

    private record PreparedRow(RowRec row, List<PreparedItem> items) {
    }

    private record PreparedItem(ItemRec item, ItemSelection selection,
                                List<CandidateView> candidates, String suggestedValue) {
    }

    private record RowOutcome(String result, List<ApplyItemResult> items) {
    }
}
