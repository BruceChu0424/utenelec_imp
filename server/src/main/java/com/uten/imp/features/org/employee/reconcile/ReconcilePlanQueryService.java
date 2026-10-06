package com.uten.imp.features.org.employee.reconcile;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSensitiveWritePolicy;
import com.uten.imp.features.org.employee.reconcile.ReconcilePlanStore.ItemRec;
import com.uten.imp.features.org.employee.reconcile.ReconcilePlanStore.PlanRow;
import com.uten.imp.features.org.employee.reconcile.ReconcilePlanStore.RowRec;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.CandidateView;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.ClaimView;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.Counts;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.NoticeView;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.BasisView;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.EmployeeRef;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.ItemView;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.OutcomeView;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.PlanSummary;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.PlanView;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.ResultView;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.RowView;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.Capabilities;
import com.uten.imp.features.org.position.Position;
import com.uten.imp.features.org.position.PositionRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DataAccessPolicy;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * 员工资料核对计划的读取与视图装配（V810/ADR-160）：行/项密文解密、按 {@code employee:pii:view}
 * 打码、认领信息实时查询。非创建人且无 {@code employee:edit} 的读取一律 404，不暴露计划存在性。
 */
@Service
@RequiredArgsConstructor
public class ReconcilePlanQueryService {

    /** HrTaskClaim 语义：证件核对任务的 taskType（HrTaskClaimService.IDENTITY_TASK_TYPE 包私有）。 */
    static final String IDENTITY_TASK_TYPE = "identity";
    private static final String PERMISSION_LABEL = "员工证件与联系方式修改";
    private static final ZoneId BEIJING = ZoneId.of("Asia/Shanghai");
    private static final DateTimeFormatter BEIJING_MINUTES =
            DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm");
    private static final TypeReference<List<CandidateView>> CANDIDATES = new TypeReference<>() {
    };
    private static final TypeReference<Map<String, Object>> COUNTS_JSON = new TypeReference<>() {
    };

    private final ReconcilePlanStore store;
    private final EmployeeRepository empRepo;
    private final PositionRepository positionRepo;
    private final TxSessionVars tx;
    private final JdbcTemplate jdbc;
    private final ObjectMapper json;

    /** 计划详情：行/项解密（无 PII 权限时打码），执行过的项照旧返回旧新值。 */
    @Transactional(readOnly = true)
    public PlanView view(UUID planId, AuthUser actor) {
        PlanRow plan = store.findPlan(planId).orElseThrow(ReconcilePlanQueryService::notFound);
        boolean owner = actor.getId().equals(plan.actorUserId());
        if (!owner && !hasEmployeeEdit(actor)) {
            throw notFound();
        }
        List<RowRec> rows = store.findRows(planId);
        List<ItemRec> items = store.findItems(planId);
        Map<Integer, List<ItemRec>> itemsByRow = items.stream()
                .collect(Collectors.groupingBy(ItemRec::rowNo, LinkedHashMap::new, Collectors.toList()));

        Set<UUID> employeeIds = rows.stream().map(RowRec::employeeId).collect(Collectors.toSet());
        Map<UUID, Employee> employees = loadEmployees(employeeIds);
        Map<UUID, ActiveClaim> claims = activeIdentityClaims(employeeIds);

        // 行/项值列解密：批量优先，解不开的密文逐个 tryDecrypt（历史数据损坏时只影响该行显示）。
        List<String> ciphers = new ArrayList<>();
        for (ItemRec item : items) {
            addCipher(ciphers, item.oldValueEnc());
            addCipher(ciphers, item.newValueEnc());
            addCipher(ciphers, item.candidatesEnc());
        }
        Map<String, String> plain = decryptQuietly(tx, ciphers);

        boolean viewPii = canViewPii(actor);
        boolean piiEdit = canEditPii(actor);
        String actorName = actorName(plan);

        List<RowView> rowViews = new ArrayList<>(rows.size());
        for (RowRec row : rows) {
            rowViews.add(rowView(row, itemsByRow.getOrDefault(row.rowNo(), List.of()),
                    employees, claims, plain, viewPii, piiEdit, actor));
        }
        return new PlanView(
                plan.id(), plan.version(), plan.status(), plan.closedReason(),
                plan.source(), plan.origin(), actorName, plan.createdAt(), plan.expiresAt(),
                canApply(plan, owner), readOnlyReason(plan, owner, actorName),
                new Capabilities(viewPii, piiEdit),
                counts(plan.countsJson(), rows), rowViews);
    }

    /** 计划列表（创建时间倒序，页码 1 起，size 上限 100），不含量值。 */
    @Transactional(readOnly = true)
    public PageResponse<PlanSummary> list(int page, int size) {
        int normalizedPage = Math.max(1, page);
        int normalizedSize = Math.min(Math.max(1, size), 100);
        List<PlanRow> plans = store.listPlans(normalizedPage, normalizedSize);
        long total = store.countPlans();
        Map<UUID, String> actorNames = actorNames(plans);
        List<PlanSummary> summaries = plans.stream()
                .map(plan -> new PlanSummary(plan.id(), plan.createdAt(),
                        actorNames.getOrDefault(plan.id(), plan.actorUserId().toString()),
                        plan.status(), plan.closedReason(), counts(plan.countsJson(), List.of())))
                .toList();
        int totalPages = (int) ((total + normalizedSize - 1) / normalizedSize);
        return new PageResponse<>(summaries, normalizedPage, normalizedSize, total, totalPages);
    }

    // ------------------------------------------------------------------
    // 行 / 项装配
    // ------------------------------------------------------------------

    private RowView rowView(RowRec row, List<ItemRec> items,
                            Map<UUID, Employee> employees, Map<UUID, ActiveClaim> claims,
                            Map<String, String> plain, boolean viewPii, boolean piiEdit,
                            AuthUser actor) {
        Employee employee = employees.get(row.employeeId());
        List<ItemView> itemViews = new ArrayList<>(items.size());
        for (ItemRec item : items) {
            itemViews.add(itemView(item, plain, viewPii, piiEdit));
        }
        // 行原因与证件核对列表同口径：对解密后的存量号现算第一处问题（说明只含位置/长度，不带号码）。
        String reason = null;
        if ("UPDATE".equals(row.kind())) {
            String stored = items.isEmpty() ? null : plainOf(plain, items.getFirst().oldValueEnc());
            if (stored != null) {
                reason = Optional.ofNullable(IdCardUtil.check(stored)).map(p -> p.message()).orElse(null);
            }
        }
        ActiveClaim claim = claims.get(row.employeeId());
        return new RowView(
                row.rowNo(), row.kind(), employeeRef(employee),
                reason,
                claim == null ? null : new ClaimView(
                        claimantName(claim.claimedBy(), employees),
                        actor.getEmployeeId() != null && actor.getEmployeeId().equals(claim.claimedBy()),
                        claim.leaseUntil()),
                row.noticeCodes().stream().map(code -> new NoticeView(code, noticeMessage(code))).toList(),
                itemViews,
                row.result() == null ? null : new ResultView(row.result(), resultMessage(row.result())));
    }

    private ItemView itemView(ItemRec item, Map<String, String> plain, boolean viewPii, boolean piiEdit) {
        String oldValue = plainOf(plain, item.oldValueEnc());
        String newValue = plainOf(plain, item.newValueEnc());
        List<CandidateView> candidates = parseCandidates(plainOf(plain, item.candidatesEnc()));
        List<Integer> diffPositions = item.diffPositions();
        List<Integer> suspectPositions = item.suspectPositions();
        if (!viewPii) {
            // 无 employee:pii:view：值打码（保留后四位），位置与候选不给。
            oldValue = IdCardUtil.mask(oldValue);
            newValue = IdCardUtil.mask(newValue);
            candidates = List.of();
            diffPositions = List.of();
            suspectPositions = List.of();
        }
        String basisLabel = ReconcilePlanViews.basisLabel(item.basisCode());
        return new ItemView(
                item.itemNo(), item.fieldCode(), "证件号码", item.writePath(),
                oldValue, newValue, diffPositions,
                basisLabel == null ? null : new BasisView(item.basisCode(), basisLabel),
                item.tier(),
                item.probability() == null ? null : Double.valueOf(item.probability().doubleValue()),
                item.preselected(),
                piiEdit,
                piiEdit ? null : PERMISSION_LABEL,
                candidates, suspectPositions,
                item.noteCodes().stream().map(ReconcilePlanQueryService::noticeMessage).toList(),
                item.outcome() == null ? null
                        : new OutcomeView(item.outcome(), item.outcomeCode(), item.outcomeMessage()));
    }

    private static String resultMessage(String result) {
        return switch (result) {
            case "APPLIED" -> "已更正";
            case "PARTIAL" -> "部分更正";
            case "SKIPPED" -> "已跳过（原因见各项结果）";
            case "FAILED" -> "更正失败（原因见各项结果）";
            default -> null;
        };
    }

    private static String noticeMessage(String code) {
        try {
            return ReconcileNotice.valueOf(code).message();
        } catch (IllegalArgumentException unknown) {
            return code;
        }
    }

    private List<CandidateView> parseCandidates(String candidatesJson) {
        if (candidatesJson == null || candidatesJson.isBlank()) {
            return List.of();
        }
        try {
            List<CandidateView> parsed = json.readValue(candidatesJson, CANDIDATES);
            return parsed == null ? List.of() : parsed;
        } catch (Exception unreadable) {
            return List.of();
        }
    }

    // ------------------------------------------------------------------
    // 计划头装配
    // ------------------------------------------------------------------

    private static boolean canApply(PlanRow plan, boolean owner) {
        return owner && "OPEN".equals(plan.status())
                && plan.expiresAt() != null && plan.expiresAt().isAfter(OffsetDateTime.now());
    }

    private static String readOnlyReason(PlanRow plan, boolean owner, String actorName) {
        if (!owner) {
            return "这是 " + actorName + " 的核对，只能查看";
        }
        if ("CLOSED".equals(plan.status())) {
            return "EXPIRED".equals(plan.closedReason()) ? "核对计划已过期" : "核对计划已放弃";
        }
        if ("APPLYING".equals(plan.status())) {
            return "核对结果正在执行更正，请稍后刷新";
        }
        if (plan.expiresAt() != null && !plan.expiresAt().isAfter(OffsetDateTime.now())) {
            return "核对计划已过期";
        }
        return null;
    }

    /** 生成时统计（rows/update/updateItems/info/same）读计划存的 json；执行计数从行结果现算。 */
    private Counts counts(String countsJson, List<RowRec> rows) {
        Map<String, Object> stored = Map.of();
        if (countsJson != null && !countsJson.isBlank()) {
            try {
                stored = json.readValue(countsJson, COUNTS_JSON);
            } catch (Exception unreadable) {
                stored = Map.of();
            }
        }
        int applied = 0;
        int skipped = 0;
        int failed = 0;
        for (RowRec row : rows) {
            if ("APPLIED".equals(row.result()) || "PARTIAL".equals(row.result())) {
                applied++;
            } else if ("SKIPPED".equals(row.result())) {
                skipped++;
            } else if ("FAILED".equals(row.result())) {
                failed++;
            }
        }
        return new Counts(
                intValue(stored.get("rows"), rows.size()),
                intValue(stored.get("update"), 0),
                intValue(stored.get("updateItems"), 0),
                intValue(stored.get("info"), 0),
                intValue(stored.get("same"), 0),
                applied, skipped, failed);
    }

    private static int intValue(Object value, int fallback) {
        return value instanceof Number number ? number.intValue() : fallback;
    }

    private EmployeeRef employeeRef(Employee employee) {
        if (employee == null) {
            return new EmployeeRef(null, null, null, null, null, null);
        }
        String deptName = employee.getDepartment() == null ? null : employee.getDepartment().getName();
        String positionName = null;
        if (employee.getPosition() != null) {
            positionName = positionRepo.findById(employee.getPosition().getId())
                    .map(Position::getName).orElse(null);
        }
        return new EmployeeRef(employee.getId(), employee.getCode(), employee.getFullName(),
                deptName, positionName, employee.getHireDate());
    }

    private Map<UUID, Employee> loadEmployees(Set<UUID> employeeIds) {
        if (employeeIds.isEmpty()) {
            return Map.of();
        }
        return empRepo.findAllWithDepartmentByIdIn(new LinkedHashSet<>(employeeIds)).stream()
                .collect(Collectors.toMap(Employee::getId, Function.identity(), (a, b) -> a));
    }

    private String actorName(PlanRow plan) {
        if (plan.actorEmployeeId() != null) {
            String name = empRepo.findById(plan.actorEmployeeId()).map(Employee::getFullName).orElse(null);
            if (name != null && !name.isBlank()) {
                return name;
            }
        }
        return plan.actorUserId().toString();
    }

    private Map<UUID, String> actorNames(List<PlanRow> plans) {
        Set<UUID> employeeIds = plans.stream().map(PlanRow::actorEmployeeId)
                .filter(Objects::nonNull).collect(Collectors.toSet());
        Map<UUID, String> namesByEmployee = employeeIds.isEmpty() ? Map.of()
                : empRepo.findAllById(employeeIds).stream()
                        .collect(Collectors.toMap(Employee::getId, Employee::getFullName, (a, b) -> a));
        Map<UUID, String> byPlan = new HashMap<>();
        for (PlanRow plan : plans) {
            byPlan.put(plan.id(), namesByEmployee.getOrDefault(plan.actorEmployeeId(),
                    plan.actorUserId().toString()));
        }
        return byPlan;
    }

    private String claimantName(UUID claimedBy, Map<UUID, Employee> rowEmployees) {
        Employee known = rowEmployees.get(claimedBy);
        if (known != null) {
            return known.getFullName();
        }
        return empRepo.findById(claimedBy).map(Employee::getFullName).orElse("同事");
    }

    // ------------------------------------------------------------------
    // 认领 / 权限 / 小工具（同包服务共用）
    // ------------------------------------------------------------------

    /** 活跃认领（released_at IS NULL 且租约未过）；employeeId → 认领。 */
    Map<UUID, ActiveClaim> activeIdentityClaims(Collection<UUID> employeeIds) {
        if (employeeIds == null || employeeIds.isEmpty()) {
            return Map.of();
        }
        List<ActiveClaim> claims = jdbc.query("""
                SELECT employee_id, claimed_by, lease_until
                FROM hr_task_claims
                WHERE task_type = ? AND released_at IS NULL AND lease_until > now() AND employee_id = ANY (?)
                """, ps -> {
            ps.setString(1, IDENTITY_TASK_TYPE);
            ps.setArray(2, ps.getConnection().createArrayOf("uuid", employeeIds.toArray(UUID[]::new)));
        }, (rs, i) -> new ActiveClaim(rs.getObject("employee_id", UUID.class),
                rs.getObject("claimed_by", UUID.class),
                rs.getObject("lease_until", OffsetDateTime.class)));
        return claims.stream().collect(Collectors.toMap(ActiveClaim::employeeId,
                Function.identity(), (a, b) -> a));
    }

    record ActiveClaim(UUID employeeId, UUID claimedBy, OffsetDateTime leaseUntil) {

        String leaseUntilText() {
            return leaseUntil == null ? "" : leaseUntil.atZoneSameInstant(BEIJING).format(BEIJING_MINUTES);
        }
    }

    /** 认领占用的中文提示（不含 6 位以上连续数字，满足库 CHECK）。 */
    static String claimedByOtherMessage(String claimantName, ActiveClaim claim) {
        return ReconcileNotice.CLAIMED_BY_OTHER.message(claimantName, claim.leaseUntilText());
    }

    static ApiException notFound() {
        return new ApiException(ErrorCode.NOT_FOUND, "核对计划不存在");
    }

    /** PII 判定与 EmployeeSensitiveWritePolicy / HrTaskService 同法：超管全有。 */
    static boolean canViewPii(AuthUser actor) {
        return actor.isSuperAdmin() || actor.getPermissions().contains(DataAccessPolicy.PII_VIEW);
    }

    static boolean canEditPii(AuthUser actor) {
        return actor.isSuperAdmin()
                || actor.getPermissions().contains(EmployeeSensitiveWritePolicy.PII_EDIT);
    }

    static boolean hasEmployeeEdit(AuthUser actor) {
        return actor.isSuperAdmin() || actor.getPermissions().contains("employee:edit");
    }

    /**
     * 批量解密 + 失败兜底：先 {@link TxSessionVars#decryptAll}；批量失败（任一密文损坏会让
     * PostgreSQL 作废整个事务）时退回逐条 {@link TxSessionVars#tryDecrypt}，解不开的密文
     * 直接从结果里缺席，由调用方按「没有值」处理。
     */
    static Map<String, String> decryptQuietly(TxSessionVars tx, Collection<String> ciphers) {
        List<String> present = ciphers == null ? List.of() : ciphers.stream()
                .filter(cipher -> cipher != null && !cipher.isBlank()).distinct().toList();
        if (present.isEmpty()) {
            return Map.of();
        }
        try {
            return tx.decryptAll(present);
        } catch (RuntimeException batchFailed) {
            Map<String, String> recovered = new HashMap<>();
            for (String cipher : present) {
                tx.tryDecrypt(cipher).ifPresent(value -> recovered.put(cipher, value));
            }
            return Map.copyOf(recovered);
        }
    }

    private static void addCipher(List<String> ciphers, String cipher) {
        if (cipher != null && !cipher.isBlank()) {
            ciphers.add(cipher);
        }
    }

    /**
     * 密文为空的值列 (无候选档位的新值/候选、存量档案没有证件号的旧值) 直接按「没有值」处理：
     * decryptQuietly 返回的不可变 Map 不接受 null 键。
     */
    private static String plainOf(Map<String, String> plain, String cipher) {
        return cipher == null ? null : plain.get(cipher);
    }
}
