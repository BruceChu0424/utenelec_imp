package com.uten.imp.features.org.employee.reconcile;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeIdentityCheck;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSensitive;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.features.org.employee.reconcile.IdRepairAdvisor.IdRepairEvidence;
import com.uten.imp.features.org.employee.reconcile.IdRepairAdvisor.IdRepairTier;
import com.uten.imp.features.org.employee.reconcile.IdRepairAdvisor.IdSuggestion;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.CandidateView;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.PlanView;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.Duration;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 生成「员工资料核对计划」（V810/ADR-160）：人事在证件核对页多选员工后，服务端解密证件号、
 * 用 {@link IdRepairAdvisor} 算修复建议，值经 pgcrypto 加密落库（明文只在内存流转，绝不写日志）。
 * 计划有效期 24 小时，过期未执行的由 {@link ReconcilePlanHousekeeping} 关闭并清掉未执行值。
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class ReconcilePlanService {

    /** 证件核对范围：在职与试用期（与 HrTaskService 的证件核对任务同口径）。 */
    private static final Set<String> IN_SCOPE_STATUSES = Set.of("active", "probation");
    /** ADR-160：计划有效期上限 24 小时。 */
    private static final Duration PLAN_VALIDITY = Duration.ofHours(24);

    private final EmployeeRepository empRepo;
    private final EmployeeSensitiveRepository sensitiveRepo;
    private final ReconcilePlanStore store;
    private final ReconcilePlanQueryService queryService;
    private final TxSessionVars tx;
    private final AuditService audit;
    private final JdbcTemplate jdbc;
    private final ObjectMapper json;

    /** 多选员工生成证件修复计划；全都不在核对范围时 422。 */
    @Transactional
    public PlanView createIdRepairPlan(AuthUser actor, List<UUID> employeeIds) {
        tx.bind();
        List<UUID> distinct = employeeIds.stream().distinct().toList();
        List<Employee> employees = empRepo.findAllWithDepartmentByIdIn(new LinkedHashSet<>(distinct))
                .stream()
                .filter(employee -> !employee.isDeleted())
                .filter(employee -> IN_SCOPE_STATUSES.contains(employee.getStatus()))
                .sorted(Comparator.comparing(Employee::getCode,
                        Comparator.nullsLast(Comparator.naturalOrder())))
                .toList();
        if (employees.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "所选员工都不在证件核对范围内");
        }

        Map<UUID, EmployeeSensitive> sensitive = sensitiveRepo
                .findAllByEmployeeIdIn(employees.stream().map(Employee::getId).toList()).stream()
                .collect(Collectors.toMap(EmployeeSensitive::getEmployeeId, s -> s, (a, b) -> a));
        Set<UUID> superAdminBound = superAdminEmployeeIds(
                employees.stream().map(Employee::getId).toList());

        // 批量解密证件号与出生日期密文；解不开的按 CIPHER_UNREADABLE 转 INFO 行。
        List<String> ciphers = new ArrayList<>();
        for (Employee employee : employees) {
            EmployeeSensitive s = sensitive.get(employee.getId());
            if (s == null) {
                continue;
            }
            if (s.getIdCardEnc() != null && !s.getIdCardEnc().isBlank()) {
                ciphers.add(s.getIdCardEnc());
            }
            if (s.getBirthDateEnc() != null && !s.getBirthDateEnc().isBlank()) {
                ciphers.add(s.getBirthDateEnc());
            }
        }
        Map<String, String> plain = ReconcilePlanQueryService.decryptQuietly(tx, ciphers);

        // 证据查重底表：全部非空证件号哈希（几千行规模一次全读；本人当前哈希不排除——存量号
        // 本身校验不过，不会成为候选，剔除无意义）。
        Set<String> takenHashes = Set.copyOf(jdbc.queryForList(
                "SELECT id_card_hash FROM employee_sensitive WHERE id_card_hash IS NOT NULL", String.class));

        List<DraftRow> drafts = new ArrayList<>(employees.size());
        int rowNo = 0;
        for (Employee employee : employees) {
            DraftRow draft = draftRow(++rowNo, employee,
                    sensitive.get(employee.getId()), superAdminBound.contains(employee.getId()),
                    plain, takenHashes);
            drafts.add(draft);
        }

        PlanDraft plan = persist(actor, drafts);
        log.info("员工资料核对计划已生成: planId={}, {} 人 {} 处待更正 (操作人不打印任何证件号)",
                plan.id(), plan.rowCount(), plan.updateItems());
        return queryService.view(plan.id(), actor);
    }

    /** 创建人放弃计划：立即关闭并清掉未执行项的值密文（幂等，重复放弃仍成功）。 */
    @Transactional
    public void discard(AuthUser actor, UUID planId) {
        tx.bind();
        ReconcilePlanStore.PlanRow plan = store.lockPlan(planId)
                .orElseThrow(ReconcilePlanQueryService::notFound);
        if (!actor.getId().equals(plan.actorUserId())) {
            throw ReconcilePlanQueryService.notFound();
        }
        if ("APPLYING".equals(plan.status())) {
            // 正在执行的更正轮不能放弃（行结果还在回写），租约超时由 Housekeeping 回收后再试。
            throw ReconcileApplyService.conflict("RECONCILE_PLAN_BUSY",
                    "这个核对正在执行更正，请稍后刷新查看结果");
        }
        if ("CLOSED".equals(plan.status())) {
            return;
        }
        store.closePlan(planId, "DISCARDED");
        audit.logCommittedChange(actor.getId(), actor.getLoginAccount(),
                "employee_reconcile.discarded", "employee_reconcile_plans", planId.toString(),
                "已放弃核对，未执行的更正值已清空", Map.of("closedReason", "DISCARDED"));
    }

    // ------------------------------------------------------------------
    // 逐人建议
    // ------------------------------------------------------------------

    private DraftRow draftRow(int rowNo, Employee employee, EmployeeSensitive sensitive,
                              boolean superAdminBound, Map<String, String> plain,
                              Set<String> takenHashes) {
        List<String> notices = new ArrayList<>();
        String idCardEnc = sensitive == null ? null : sensitive.getIdCardEnc();
        String idPlain = idCardEnc == null ? null : plain.get(idCardEnc);
        boolean unreadable = idCardEnc != null && !idCardEnc.isBlank() && idPlain == null;
        String normalized = idPlain == null ? null : IdCardUtil.normalize(idPlain);

        if (unreadable) {
            notices.add(ReconcileNotice.CIPHER_UNREADABLE.code());
            return new DraftRow(rowNo, employee.getId(), employee.getVersion(), "INFO", notices, null);
        }
        String idType = employee.getIdType();
        if (idType == null || !EmployeeIdentityCheck.RESIDENT_ID.equals(idType)) {
            notices.add(ReconcileNotice.NOT_RESIDENT_ID.code());
            return new DraftRow(rowNo, employee.getId(), employee.getVersion(), "INFO", notices, null);
        }
        if (superAdminBound) {
            notices.add(ReconcileNotice.SUPER_ADMIN_BOUND.code());
            return new DraftRow(rowNo, employee.getId(), employee.getVersion(), "INFO", notices, null);
        }
        if (normalized != null && IdCardUtil.check(normalized) == null) {
            notices.add(ReconcileNotice.ALREADY_VALID.code());
            return new DraftRow(rowNo, employee.getId(), employee.getVersion(), "SAME", notices, null);
        }

        IdRepairEvidence evidence = evidence(employee, sensitive, normalized, plain, takenHashes);
        IdSuggestion suggestion = IdRepairAdvisor.suggest(normalized, evidence);
        if (suggestion.candidates().isEmpty() && suggestion.tier() != IdRepairTier.NONE) {
            // 理论上不可达（有候选才有档位）；防御性兜底为 INFO 行，不产生可执行项。
            notices.add(ReconcileNotice.MULTIPLE_ERRORS.code());
            return new DraftRow(rowNo, employee.getId(), employee.getVersion(), "INFO", notices, null);
        }
        DraftItem item = draftItem(normalized, suggestion);
        return new DraftRow(rowNo, employee.getId(), employee.getVersion(), "UPDATE", notices, item);
    }

    private DraftItem draftItem(String oldValue, IdSuggestion suggestion) {
        String newValue = null;
        List<Integer> diffPositions = List.of();
        BigDecimal probability = null;
        List<CandidateView> candidates = List.of();
        if (!suggestion.candidates().isEmpty()) {
            var first = suggestion.candidates().getFirst();
            newValue = first.value();
            diffPositions = first.diffPositions();
            probability = BigDecimal.valueOf(first.p());
            candidates = suggestion.candidates().stream()
                    .map(candidate -> new CandidateView(candidate.value(),
                            Double.valueOf(candidate.p()), candidate.diffPositions()))
                    .toList();
        }
        List<String> noteCodes = suggestion.reasonCode() == null
                ? List.of()
                : List.of(suggestion.reasonCode());
        return new DraftItem(
                oldValue, newValue, candidates, diffPositions, suggestion.suspectPositions(),
                suggestion.basisCode(), suggestion.tier().name(), probability,
                suggestion.tier() == IdRepairTier.HIGH, noteCodes);
    }

    /** 独立证据：出生日期取密文解密值、性别取档案；只有与证号推导冲突时才算独立证据。 */
    private IdRepairEvidence evidence(Employee employee, EmployeeSensitive sensitive,
                                      String normalized, Map<String, String> plain,
                                      Set<String> takenHashes) {
        LocalDate birth = null;
        if (sensitive != null && sensitive.getBirthDateEnc() != null) {
            String birthText = plain.get(sensitive.getBirthDateEnc());
            if (birthText != null && !birthText.isBlank()) {
                try {
                    birth = LocalDate.parse(birthText);
                } catch (DateTimeParseException ignored) {
                    birth = null;
                }
            }
        }
        String gender = employee.getGender();
        boolean birthIndependent = false;
        boolean genderIndependent = false;
        if (normalized != null) {
            LocalDate fromNumber = birthSegmentOf(normalized);
            birthIndependent = birth != null && (fromNumber == null || !fromNumber.equals(birth));
            if (gender != null) {
                Boolean parityMatches = genderParityMatches(normalized, gender);
                genderIndependent = parityMatches == null || !parityMatches;
            }
        }
        return new IdRepairEvidence(birth, birthIndependent, gender, genderIndependent,
                employee.getHireDate(), null, tx::hmac, takenHashes);
    }

    /** 证号第 7-14 位按生日解析；解析不出返回 null。 */
    private static LocalDate birthSegmentOf(String normalized) {
        if (normalized.length() < 14) {
            return null;
        }
        for (int i = 6; i < 14; i++) {
            if (!Character.isDigit(normalized.charAt(i))) {
                return null;
            }
        }
        try {
            return LocalDate.parse(normalized.substring(6, 14), DateTimeFormatter.BASIC_ISO_DATE);
        } catch (DateTimeParseException invalid) {
            return null;
        }
    }

    /** 第 17 位奇偶与档案性别是否一致；解析不出返回 null（视为独立证据）。 */
    private static Boolean genderParityMatches(String normalized, String gender) {
        if (normalized.length() < 18 || !Character.isDigit(normalized.charAt(16)) || gender == null) {
            return null;
        }
        String implied = (normalized.charAt(16) - '0') % 2 == 1 ? "male" : "female";
        return implied.equals(gender);
    }

    // ------------------------------------------------------------------
    // 落库
    // ------------------------------------------------------------------

    private PlanDraft persist(AuthUser actor, List<DraftRow> drafts) {
        int update = 0;
        int info = 0;
        int same = 0;
        int updateItems = 0;
        for (DraftRow draft : drafts) {
            switch (draft.kind()) {
                case "UPDATE" -> update++;
                case "INFO" -> info++;
                case "SAME" -> same++;
                default -> { }
            }
            if (draft.item() != null) {
                updateItems++;
            }
        }
        Map<String, Object> counts = new LinkedHashMap<>();
        counts.put("rows", drafts.size());
        counts.put("update", update);
        counts.put("updateItems", updateItems);
        counts.put("info", info);
        counts.put("same", same);

        // 值密文批量生成：旧值/新值/候选 JSON 一次 encryptAll。
        List<String> plains = new ArrayList<>();
        for (DraftRow draft : drafts) {
            DraftItem item = draft.item();
            if (item == null) {
                continue;
            }
            addPlain(plains, item.oldValue());
            addPlain(plains, item.newValue());
            if (!item.candidates().isEmpty()) {
                addPlain(plains, candidatesJson(item.candidates()));
            }
        }
        Map<String, String> encrypted = tx.encryptAll(plains);

        UUID planId = store.insertPlan("ID_REPAIR", "PAGE", actor.getId(),
                actor.getEmployeeId(), writeJson(counts),
                OffsetDateTime.now().plus(PLAN_VALIDITY));
        for (DraftRow draft : drafts) {
            store.insertRow(planId, draft.rowNo(), draft.employeeId(), draft.employeeVersion(),
                    draft.kind(), draft.noticeCodes());
            DraftItem item = draft.item();
            if (item == null) {
                continue;
            }
            store.insertItem(planId, draft.rowNo(), 1, "idNumber", "CHANGE_IDENTITY",
                    cipherOf(encrypted, item.oldValue()),
                    cipherOf(encrypted, item.newValue()),
                    item.candidates().isEmpty() ? null : encrypted.get(candidatesJson(item.candidates())),
                    item.diffPositions(), item.suspectPositions(), item.basisCode(), item.tier(),
                    item.probability(), item.preselected(), item.noteCodes());
        }

        audit.logCommittedChange(actor.getId(), actor.getLoginAccount(),
                "employee_reconcile.plan_created", "employee_reconcile_plans", planId.toString(),
                planResultText(drafts.size(), updateItems),
                Map.of("source", "ID_REPAIR", "rows", drafts.size(),
                        "update", update, "info", info, "same", same));
        return new PlanDraft(planId, drafts.size(), updateItems);
    }

    private static String planResultText(int rows, int updateItems) {
        return updateItems > 0
                ? rows + " 人 " + updateItems + " 处待更正"
                : rows + " 人核对完成，无需更正";
    }

    private String candidatesJson(List<CandidateView> candidates) {
        return writeJson(candidates);
    }

    private String writeJson(Object value) {
        try {
            return json.writeValueAsString(value);
        } catch (Exception failure) {
            throw new IllegalStateException("核对计划 JSON 序列化失败", failure);
        }
    }

    private Set<UUID> superAdminEmployeeIds(Collection<UUID> employeeIds) {
        if (employeeIds.isEmpty()) {
            return Set.of();
        }
        // 与 EmployeeCommandService.changeIdentity 的超管判定同口径（不过滤已删账号，宁可多拦）。
        return Set.copyOf(jdbc.query("""
                SELECT employee_id FROM users
                WHERE is_super_admin AND employee_id IS NOT NULL AND employee_id = ANY (?)
                """, ps -> ps.setArray(1, ps.getConnection()
                        .createArrayOf("uuid", employeeIds.toArray(UUID[]::new))),
                (rs, i) -> rs.getObject("employee_id", UUID.class)));
    }

    private static void addPlain(List<String> plains, String value) {
        if (value != null && !value.isBlank()) {
            plains.add(value);
        }
    }

    /**
     * 旧值可能为空 (存量档案没有证件号)、新值/候选在无候选档位 (NONE) 下为空：
     * encryptAll 返回的不可变 Map 不接受 null 键，这里按「没有值密文」放行。
     */
    private static String cipherOf(Map<String, String> encrypted, String plain) {
        return plain == null ? null : encrypted.get(plain);
    }

    private record DraftRow(int rowNo, UUID employeeId, int employeeVersion, String kind,
                            List<String> noticeCodes, DraftItem item) {
    }

    private record DraftItem(String oldValue, String newValue, List<CandidateView> candidates,
                             List<Integer> diffPositions, List<Integer> suspectPositions,
                             String basisCode, String tier, BigDecimal probability,
                             boolean preselected, List<String> noteCodes) {
    }

    private record PlanDraft(UUID id, int rowCount, int updateItems) {
    }
}
