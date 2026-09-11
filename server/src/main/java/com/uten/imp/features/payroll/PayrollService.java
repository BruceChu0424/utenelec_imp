package com.uten.imp.features.payroll;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.application.port.EmployeeNameLookupPort;
import com.uten.imp.application.port.HrNoticePort;
import com.uten.imp.features.payroll.dto.PayrollBatchCreateRequest;
import com.uten.imp.features.payroll.dto.PayrollBatchDto;
import com.uten.imp.features.payroll.dto.PayrollItemDto;
import com.uten.imp.features.payroll.dto.PayrollPdf;
import com.uten.imp.features.payroll.dto.PayrollSlipDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * 工资服务：批次状态机（DRAFT → SUBMITTED → APPROVED/REJECTED → PUBLISHED）+
 * 工资条生成（薪酬字段 pgp 密文在事务内批量解密）+ 员工自助查看/下载已发布工资条（个人仅见本人已发布）。
 */
@Service
@RequiredArgsConstructor
public class PayrollService {

    private static final Set<String> SLIP_FILTERS =
            Set.of("PENDING", "PUBLISHED", "UNVIEWED", "VIEWED", "DOWNLOADED");
    private static final Set<String> BATCH_STATUSES =
            Set.of("DRAFT", "SUBMITTED", "APPROVED", "REJECTED", "PUBLISHED");

    private final PayrollBatchRepository batchRepository;
    private final PayrollSlipRepository slipRepository;
    private final PayrollItemRepository itemRepository;
    private final PayrollVariableInputRepository variableInputRepository;
    private final PayrollEmployeeQuery employeeQuery;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final PayrollPdfService pdfService;
    private final HrNoticePort hrNotice;
    private final EmployeeNameLookupPort employeeNames;

    @Transactional(readOnly = true)
    public PageResponse<PayrollSlipDto> listSlips(
            String rawState,
            Integer year,
            Integer month,
            UUID departmentId,
            int page,
            int size) {
        String state = normalizeSlipState(rawState);
        Short normalizedYear = normalizeYear(year);
        Short normalizedMonth = normalizeMonth(month);
        AuthUser user = requireStaff();
        boolean canViewAll = has(user, "payroll:view:all");
        if (!canViewAll) {
            require(user, "payroll:view:self");
        }
        List<UUID> departmentIds = departmentId == null
                ? List.of()
                : employeeQuery.findDepartmentSubtreeIds(departmentId);
        if (departmentId != null && departmentIds.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "工资筛选部门不存在");
        }

        Specification<PayrollSlip> spec = (root, query, cb) -> {
            List<Predicate> predicates = new ArrayList<>();
            predicates.add(cb.isTrue(root.get("active")));
            if (!canViewAll) {
                predicates.add(cb.equal(root.get("employeeId"), user.getEmployeeId()));
                predicates.add(cb.equal(root.get("status"), "PUBLISHED"));
            }
            addSlipStatePredicate(predicates, root, cb, state);
            if (normalizedYear != null) {
                predicates.add(cb.equal(root.get("payrollYear"), normalizedYear));
            }
            if (normalizedMonth != null) {
                predicates.add(cb.equal(root.get("payrollMonth"), normalizedMonth));
            }
            if (!departmentIds.isEmpty()) {
                predicates.add(root.get("departmentIdSnapshot").in(departmentIds));
            }
            return cb.and(predicates.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, Sort.by(
                Sort.Order.desc("payrollYear"),
                Sort.Order.desc("payrollMonth"),
                Sort.Order.asc("employeeCodeSnapshot"),
                Sort.Order.asc("id")));
        Page<PayrollSlip> result = slipRepository.findAll(spec, pageable);
        return new PageResponse<>(
                mapSlips(result.getContent()),
                pageable.getPageNumber() + 1,
                pageable.getPageSize(),
                result.getTotalElements(),
                result.getTotalPages());
    }

    @Transactional(readOnly = true)
    public PayrollSlipDto getSlip(UUID id) {
        PayrollSlip slip = requireSlip(id);
        assertCanReadSlip(slip);
        return mapSlip(slip, itemsFor(List.of(slip)).getOrDefault(slip.getId(), List.of()));
    }

    @Transactional
    public PayrollSlipDto markViewed(UUID id) {
        tx.bind();
        PayrollSlip slip = slipRepository.findByIdForUpdate(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "工资条不存在"));
        assertSelfPublishedSlip(slip);
        if (slip.getViewedAt() == null) {
            slip.setViewedAt(Instant.now());
            slipRepository.save(slip);
        }
        return mapSlip(slip, itemsFor(List.of(slip)).getOrDefault(slip.getId(), List.of()));
    }

    @Transactional
    public PayrollPdf downloadSlip(UUID id) {
        tx.bind();
        PayrollSlip slip = slipRepository.findByIdForUpdate(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "工资条不存在"));
        AuthUser user = requireStaff();
        boolean self = slip.getEmployeeId().equals(user.getEmployeeId());
        if (self) {
            assertSelfPublishedSlip(slip);
            if (slip.getDownloadedAt() == null) {
                slip.setDownloadedAt(Instant.now());
                slipRepository.save(slip);
            }
        } else {
            if (!slip.isActive() || !has(user, "payroll:view:all") || !has(user, "payroll:export")) {
                throw new ApiException(ErrorCode.NOT_FOUND, "工资条不存在");
            }
        }
        PayrollSlipDto dto = mapSlip(
                slip, itemsFor(List.of(slip)).getOrDefault(slip.getId(), List.of()));
        return pdfService.render(dto);
    }

    @Transactional(readOnly = true)
    public PageResponse<PayrollBatchDto> listBatches(
            Integer year,
            Integer month,
            String rawStatus,
            UUID departmentId,
            int page,
            int size) {
        AuthUser user = requireStaff();
        requireAny(user, "payroll:generate", "payroll:review", "payroll:publish", "payroll:view:all");
        Short normalizedYear = normalizeYear(year);
        Short normalizedMonth = normalizeMonth(month);
        String status = normalizeBatchStatus(rawStatus);
        Specification<PayrollBatch> spec = (root, query, cb) -> {
            List<Predicate> predicates = new ArrayList<>();
            if (normalizedYear != null) {
                predicates.add(cb.equal(root.get("payrollYear"), normalizedYear));
            }
            if (normalizedMonth != null) {
                predicates.add(cb.equal(root.get("payrollMonth"), normalizedMonth));
            }
            if (status != null) {
                predicates.add(cb.equal(root.get("status"), status));
            }
            if (departmentId != null) {
                predicates.add(cb.equal(root.get("departmentId"), departmentId));
            }
            return cb.and(predicates.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, Sort.by(
                Sort.Order.desc("payrollYear"),
                Sort.Order.desc("payrollMonth"),
                Sort.Order.desc("createdAt"),
                Sort.Order.desc("id")));
        Page<PayrollBatch> result = batchRepository.findAll(spec, pageable);
        List<PayrollBatchDto> items = result.getContent().stream()
                .map(batch -> mapBatch(batch, List.of()))
                .toList();
        return new PageResponse<>(
                items,
                pageable.getPageNumber() + 1,
                pageable.getPageSize(),
                result.getTotalElements(),
                result.getTotalPages());
    }

    @Transactional(readOnly = true)
    public PayrollBatchDto getBatch(UUID id) {
        AuthUser user = requireStaff();
        requireAny(user, "payroll:generate", "payroll:review", "payroll:publish", "payroll:view:all");
        PayrollBatch batch = requireBatch(id);
        List<PayrollSlip> slips = slipRepository.findByBatchIdOrderByEmployeeCodeSnapshotAscIdAsc(id);
        return mapBatch(batch, mapSlips(slips));
    }

    /** 生成工资批次：单事务按范围取在册员工、拒绝同月份已有有效工资条者、批量解密薪资密文、逐人构造工资条与项目并累加批次合计。 */
    @Transactional
    public PayrollBatchDto createBatch(PayrollBatchCreateRequest request) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "payroll:generate");
        String departmentName = request.departmentId() == null
                ? null
                : employeeQuery.findDepartmentName(request.departmentId())
                        .orElseThrow(() -> new ApiException(
                                ErrorCode.NOT_FOUND, "工资范围部门不存在"));

        List<PayrollEmployeeQuery.Candidate> candidates =
                employeeQuery.findCandidates(request.departmentId());
        if (candidates.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "所选范围没有可生成工资的在册员工");
        }
        List<UUID> employeeIds = candidates.stream()
                .map(PayrollEmployeeQuery.Candidate::employeeId)
                .toList();
        if (slipRepository.countActiveConflicts(
                (short) request.year(), (short) request.month(), employeeIds) > 0) {
            throw new ApiException(ErrorCode.CONFLICT, "所选员工中已有该月份的有效工资条");
        }

        Map<UUID, PayrollVariableInput> variables = variableInputRepository
                .findForPeriod((short) request.year(), (short) request.month(), employeeIds)
                .stream()
                .collect(Collectors.toMap(PayrollVariableInput::getEmployeeId, Function.identity()));
        Collection<String> ciphers = candidates.stream()
                .flatMap(candidate -> java.util.stream.Stream.of(
                        candidate.baseSalaryCipher(),
                        candidate.performanceSalaryCipher(),
                        candidate.allowanceCipher()))
                .filter(value -> value != null && !value.isBlank())
                .toList();
        Map<String, String> decrypted = tx.decryptAll(ciphers);

        PayrollBatch batch = new PayrollBatch();
        batch.setPayrollYear((short) request.year());
        batch.setPayrollMonth((short) request.month());
        batch.setDepartmentId(request.departmentId());
        batch.setDepartmentNameSnapshot(departmentName);
        batch.setStatus("DRAFT");
        batch.setIncludeOvertime(request.includeOvertime());
        batch.setIncludeBonus(request.includeBonus());
        batch.setIncludeSocialInsurance(request.includeSocialInsurance());
        batch.setIncludeTax(request.includeTax());
        batch.setGeneratedBy(user.getEmployeeId());
        batchRepository.save(batch);

        List<PayrollSlip> slips = new ArrayList<>(candidates.size());
        Map<UUID, List<PayrollItem>> itemsBySlip = new LinkedHashMap<>();
        BigDecimal batchGross = BigDecimal.ZERO;
        BigDecimal batchDeduction = BigDecimal.ZERO;
        for (PayrollEmployeeQuery.Candidate candidate : candidates) {
            List<ItemAmount> amounts = buildAmounts(
                    request, candidate, variables.get(candidate.employeeId()), decrypted);
            BigDecimal gross = sum(amounts, "EARNING");
            BigDecimal deduction = sum(amounts, "DEDUCTION");

            PayrollSlip slip = new PayrollSlip();
            slip.setBatchId(batch.getId());
            slip.setEmployeeId(candidate.employeeId());
            slip.setEmployeeCodeSnapshot(candidate.employeeCode());
            slip.setEmployeeNameSnapshot(candidate.employeeName());
            slip.setDepartmentIdSnapshot(candidate.departmentId());
            slip.setDepartmentNameSnapshot(candidate.departmentName());
            slip.setPayrollYear((short) request.year());
            slip.setPayrollMonth((short) request.month());
            slip.setStatus("PENDING");
            slip.setGrossIncome(gross);
            slip.setTotalDeduction(deduction);
            slip.setNetIncome(gross.subtract(deduction));
            slips.add(slip);

            List<PayrollItem> items = new ArrayList<>(amounts.size());
            int lineNo = 1;
            for (ItemAmount amount : amounts) {
                PayrollItem item = new PayrollItem();
                item.setSlipId(slip.getId());
                item.setLineNo(lineNo++);
                item.setItemCode(amount.code());
                item.setName(amount.name());
                item.setItemType(amount.type());
                item.setAmount(amount.amount());
                item.setSourceType(amount.sourceType());
                items.add(item);
            }
            itemsBySlip.put(slip.getId(), items);
            batchGross = batchGross.add(gross);
            batchDeduction = batchDeduction.add(deduction);
        }
        slipRepository.saveAll(slips);
        itemRepository.saveAll(itemsBySlip.values().stream().flatMap(List::stream).toList());

        batch.setHeadcount(slips.size());
        batch.setGrossIncome(batchGross);
        batch.setTotalDeduction(batchDeduction);
        batch.setNetIncome(batchGross.subtract(batchDeduction));
        batchRepository.save(batch);
        return mapBatch(batch, mapSlipsWithKnownItems(slips, itemsBySlip));
    }

    @Transactional
    public PayrollBatchDto submitBatch(UUID id) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "payroll:generate");
        PayrollBatch batch = requireBatchForUpdate(id);
        if (!batch.getGeneratedBy().equals(user.getEmployeeId()) && !user.isSuperAdmin()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "仅生成该批次的员工可提交");
        }
        assertBatchStatus(batch, "DRAFT");
        batch.setStatus("SUBMITTED");
        batch.setSubmittedBy(user.getEmployeeId());
        batch.setSubmittedAt(Instant.now());
        batchRepository.save(batch);
        // 提交 → 通知审核人（弹卡 + 通知；2026-09-09 人事通知接入）
        hrNotice.notifyPayrollBatchSubmitted(
                batch.getId(), periodLabel(batch), generatorName(batch), user.getEmployeeId());
        return mapBatchWithSlips(batch);
    }

    @Transactional
    public PayrollBatchDto approveBatch(UUID id) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "payroll:review");
        PayrollBatch batch = requireBatchForUpdate(id);
        assertBatchStatus(batch, "SUBMITTED");
        batch.setStatus("APPROVED");
        batch.setApprovedBy(user.getEmployeeId());
        batch.setApprovedAt(Instant.now());
        batchRepository.save(batch);
        // 审毕 → 先办结「待审核」卡，再给 payroll:publish 持有者发「待发布」接棒卡
        //（同聚合 PAYROLL_BATCH，顺序不能反；审核人本人不收；2026-09-10 补闭环）。
        hrNotice.resolvePayrollBatch(batch.getId(), "APPROVED");
        hrNotice.notifyPayrollBatchApproved(
                batch.getId(), periodLabel(batch), user.getEmployeeId());
        return mapBatchWithSlips(batch);
    }

    @Transactional
    public PayrollBatchDto rejectBatch(UUID id, String reason) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "payroll:review");
        PayrollBatch batch = requireBatchForUpdate(id);
        assertBatchStatus(batch, "SUBMITTED");
        slipRepository.deactivateBatch(batch.getId());
        batch.setStatus("REJECTED");
        batch.setRejectedAt(Instant.now());
        batch.setRejectReason(reason.trim());
        batch.setApprovedBy(null);
        batch.setApprovedAt(null);
        batchRepository.save(batch);
        // 驳回 → 回执制单人 + 办结审核弹卡（2026-09-09 人事通知接入）
        hrNotice.notifyPayrollBatchRejected(
                batch.getId(), periodLabel(batch), reason.trim(),
                userIdOfEmployee(batch.getGeneratedBy()));
        return mapBatchWithSlips(batch);
    }

    @Transactional
    public PayrollBatchDto publishBatch(UUID id) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "payroll:publish");
        PayrollBatch batch = requireBatchForUpdate(id);
        assertBatchStatus(batch, "APPROVED");
        Instant now = Instant.now();
        int published = slipRepository.publishBatch(batch.getId(), now);
        if (published != batch.getHeadcount()) {
            throw new ApiException(ErrorCode.CONFLICT, "工资条数量或状态已变化，请刷新后重试");
        }
        batch.setStatus("PUBLISHED");
        batch.setPublishedBy(user.getEmployeeId());
        batch.setPublishedAt(now);
        batchRepository.save(batch);
        // 发布 → 持条员工逐人「工资条已发布」（普通通知不弹卡）+ 办结审核弹卡
        hrNotice.notifyPayrollPublished(
                batch.getId(), periodLabel(batch),
                slipRepository.findByBatchIdOrderByEmployeeCodeSnapshotAscIdAsc(batch.getId())
                        .stream().map(PayrollSlip::getEmployeeId).distinct().toList());
        hrNotice.resolvePayrollBatch(batch.getId(), "PUBLISHED");
        return mapBatchWithSlips(batch);
    }

    /** 批次期间文案（如「2026-09」）。 */
    private static String periodLabel(PayrollBatch batch) {
        return "%d-%02d".formatted(batch.getPayrollYear(), batch.getPayrollMonth());
    }

    /** 制单人姓名（员工档案缺失时回退「工资员」）。 */
    private String generatorName(PayrollBatch batch) {
        if (batch.getGeneratedBy() == null) return "工资员";
        return employeeNames.findName(batch.getGeneratedBy())
                .filter(name -> !name.isBlank())
                .orElse("工资员");
    }

    /** 员工档案 id → 登录账号 id（经 HrNoticePort 解析；无账号返回 null，通知侧自行跳过）。 */
    private UUID userIdOfEmployee(UUID employeeId) {
        return hrNotice.recipientUserIdOf(employeeId);
    }

    private List<ItemAmount> buildAmounts(
            PayrollBatchCreateRequest request,
            PayrollEmployeeQuery.Candidate candidate,
            PayrollVariableInput variable,
            Map<String, String> decrypted) {
        List<ItemAmount> amounts = new ArrayList<>();
        add(amounts, "BASE_SALARY", "基本工资", "EARNING",
                salary(candidate.baseSalaryCipher(), decrypted, candidate.employeeCode(), "基本工资"),
                "COMPENSATION_SNAPSHOT");
        add(amounts, "PERFORMANCE_SALARY", "绩效工资", "EARNING",
                salary(candidate.performanceSalaryCipher(), decrypted, candidate.employeeCode(), "绩效工资"),
                "COMPENSATION_SNAPSHOT");
        add(amounts, "ALLOWANCE", "津贴补贴", "EARNING",
                salary(candidate.allowanceCipher(), decrypted, candidate.employeeCode(), "津贴补贴"),
                "COMPENSATION_SNAPSHOT");
        if (variable == null) {
            return amounts;
        }
        if (request.includeOvertime()) {
            add(amounts, "OVERTIME", "加班费", "EARNING",
                    variable.getOvertimeAmount(), "VARIABLE_INPUT");
        }
        if (request.includeBonus()) {
            add(amounts, "BONUS", "奖金", "EARNING",
                    variable.getBonusAmount(), "VARIABLE_INPUT");
        }
        add(amounts, "OTHER_EARNING", "其他应发", "EARNING",
                variable.getOtherEarningAmount(), "VARIABLE_INPUT");
        if (request.includeSocialInsurance()) {
            add(amounts, "SOCIAL_INSURANCE", "社会保险", "DEDUCTION",
                    variable.getSocialInsuranceAmount(), "VARIABLE_INPUT");
            add(amounts, "HOUSING_FUND", "住房公积金", "DEDUCTION",
                    variable.getHousingFundAmount(), "VARIABLE_INPUT");
        }
        if (request.includeTax()) {
            add(amounts, "TAX", "个人所得税", "DEDUCTION",
                    variable.getTaxAmount(), "VARIABLE_INPUT");
        }
        add(amounts, "OTHER_DEDUCTION", "其他扣除", "DEDUCTION",
                variable.getOtherDeductionAmount(), "VARIABLE_INPUT");
        return amounts;
    }

    private static void add(List<ItemAmount> target, String code, String name, String type,
                            BigDecimal rawAmount, String sourceType) {
        BigDecimal amount = money(rawAmount);
        if (amount.signum() > 0) {
            target.add(new ItemAmount(code, name, type, amount, sourceType));
        }
    }

    private static BigDecimal salary(String cipher, Map<String, String> decrypted,
                                     String employeeCode, String fieldName) {
        if (cipher == null || cipher.isBlank()) {
            return BigDecimal.ZERO.setScale(2);
        }
        String plain = decrypted.get(cipher);
        try {
            BigDecimal value = new BigDecimal(plain).setScale(2, RoundingMode.UNNECESSARY);
            if (value.signum() < 0) {
                throw new ArithmeticException("negative");
            }
            return value;
        } catch (RuntimeException exception) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "员工 " + employeeCode + " 的" + fieldName + "不是有效的非负两位小数");
        }
    }

    private static BigDecimal sum(List<ItemAmount> amounts, String type) {
        return amounts.stream()
                .filter(amount -> type.equals(amount.type()))
                .map(ItemAmount::amount)
                .reduce(BigDecimal.ZERO.setScale(2), BigDecimal::add);
    }

    private PayrollBatchDto mapBatchWithSlips(PayrollBatch batch) {
        List<PayrollSlip> slips =
                slipRepository.findByBatchIdOrderByEmployeeCodeSnapshotAscIdAsc(batch.getId());
        return mapBatch(batch, mapSlips(slips));
    }

    private List<PayrollSlipDto> mapSlips(List<PayrollSlip> slips) {
        Map<UUID, List<PayrollItem>> items = itemsFor(slips);
        return slips.stream()
                .map(slip -> mapSlip(slip, items.getOrDefault(slip.getId(), List.of())))
                .toList();
    }

    private List<PayrollSlipDto> mapSlipsWithKnownItems(
            List<PayrollSlip> slips, Map<UUID, List<PayrollItem>> items) {
        return slips.stream()
                .map(slip -> mapSlip(slip, items.getOrDefault(slip.getId(), List.of())))
                .toList();
    }

    private Map<UUID, List<PayrollItem>> itemsFor(List<PayrollSlip> slips) {
        if (slips.isEmpty()) {
            return Map.of();
        }
        return itemRepository.findBySlipIdInOrderBySlipIdAscLineNoAsc(
                        slips.stream().map(PayrollSlip::getId).toList())
                .stream()
                .collect(Collectors.groupingBy(
                        PayrollItem::getSlipId, LinkedHashMap::new, Collectors.toList()));
    }

    private static PayrollSlipDto mapSlip(PayrollSlip slip, List<PayrollItem> items) {
        return new PayrollSlipDto(
                slip.getId(),
                slip.getEmployeeId(),
                slip.getEmployeeNameSnapshot(),
                slip.getEmployeeCodeSnapshot(),
                slip.getPayrollYear(),
                slip.getPayrollMonth(),
                items.stream().map(item -> new PayrollItemDto(
                        item.getName(), item.getAmount(), item.getItemType(), item.getDescription()))
                        .toList(),
                slip.getGrossIncome(),
                slip.getTotalDeduction(),
                slip.getNetIncome(),
                slip.getStatus(),
                slip.getPublishedAt(),
                slip.getViewedAt(),
                slip.getDownloadedAt(),
                slip.getRemark());
    }

    private static PayrollBatchDto mapBatch(PayrollBatch batch, List<PayrollSlipDto> slips) {
        return new PayrollBatchDto(
                batch.getId(),
                batch.getPayrollYear(),
                batch.getPayrollMonth(),
                batch.getDepartmentId(),
                batch.getDepartmentNameSnapshot(),
                batch.getStatus(),
                batch.getHeadcount(),
                batch.getGrossIncome(),
                batch.getTotalDeduction(),
                batch.getNetIncome(),
                slips,
                batch.getCreatedAt(),
                batch.getSubmittedAt(),
                batch.getApprovedAt(),
                batch.getPublishedAt(),
                batch.getRejectReason());
    }

    private void assertCanReadSlip(PayrollSlip slip) {
        AuthUser user = requireStaff();
        if (has(user, "payroll:view:all") && slip.isActive()) {
            return;
        }
        if (has(user, "payroll:view:self")
                && slip.isActive()
                && "PUBLISHED".equals(slip.getStatus())
                && slip.getEmployeeId().equals(user.getEmployeeId())) {
            return;
        }
        throw new ApiException(ErrorCode.NOT_FOUND, "工资条不存在");
    }

    private void assertSelfPublishedSlip(PayrollSlip slip) {
        AuthUser user = requireStaff();
        if (!has(user, "payroll:view:self")
                || !slip.isActive()
                || !"PUBLISHED".equals(slip.getStatus())
                || !slip.getEmployeeId().equals(user.getEmployeeId())) {
            throw new ApiException(ErrorCode.NOT_FOUND, "工资条不存在");
        }
    }

    private PayrollSlip requireSlip(UUID id) {
        return slipRepository.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "工资条不存在"));
    }

    private PayrollBatch requireBatch(UUID id) {
        return batchRepository.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "工资批次不存在"));
    }

    private PayrollBatch requireBatchForUpdate(UUID id) {
        return batchRepository.findByIdForUpdate(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "工资批次不存在"));
    }

    private static void assertBatchStatus(PayrollBatch batch, String expected) {
        if (!expected.equals(batch.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "工资批次当前为 " + batch.getStatus() + "，不能执行此操作");
        }
    }

    private static void addSlipStatePredicate(
            List<Predicate> predicates,
            Root<PayrollSlip> root,
            CriteriaBuilder cb,
            String state) {
        if (state == null) {
            return;
        }
        switch (state) {
            case "PENDING" -> predicates.add(cb.equal(root.get("status"), "PENDING"));
            case "PUBLISHED" -> predicates.add(cb.equal(root.get("status"), "PUBLISHED"));
            case "UNVIEWED" -> {
                predicates.add(cb.equal(root.get("status"), "PUBLISHED"));
                predicates.add(cb.isNull(root.get("viewedAt")));
                predicates.add(cb.isNull(root.get("downloadedAt")));
            }
            case "VIEWED" -> {
                predicates.add(cb.equal(root.get("status"), "PUBLISHED"));
                predicates.add(cb.isNotNull(root.get("viewedAt")));
                predicates.add(cb.isNull(root.get("downloadedAt")));
            }
            case "DOWNLOADED" -> {
                predicates.add(cb.equal(root.get("status"), "PUBLISHED"));
                predicates.add(cb.isNotNull(root.get("downloadedAt")));
            }
            default -> throw new IllegalStateException("未处理的工资条状态: " + state);
        }
    }

    private static String normalizeSlipState(String rawState) {
        if (rawState == null || rawState.isBlank()) {
            return null;
        }
        String normalized = rawState.trim().toUpperCase(Locale.ROOT);
        if (!SLIP_FILTERS.contains(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知工资条状态");
        }
        return normalized;
    }

    private static String normalizeBatchStatus(String rawStatus) {
        if (rawStatus == null || rawStatus.isBlank()) {
            return null;
        }
        String normalized = rawStatus.trim().toUpperCase(Locale.ROOT);
        if (!BATCH_STATUSES.contains(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知工资批次状态");
        }
        return normalized;
    }

    private static Short normalizeYear(Integer year) {
        if (year == null) {
            return null;
        }
        if (year < 2000 || year > 2200) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "工资年份必须在 2000 至 2200 之间");
        }
        return year.shortValue();
    }

    private static Short normalizeMonth(Integer month) {
        if (month == null) {
            return null;
        }
        if (month < 1 || month > 12) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "工资月份必须在 1 至 12 之间");
        }
        return month.shortValue();
    }

    private AuthUser requireStaff() {
        AuthUser user = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (user.isVisitor() || user.getEmployeeId() == null) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        return user;
    }

    private static boolean has(AuthUser user, String permission) {
        return user.isSuperAdmin() || user.getPermissions().contains(permission);
    }

    private static void require(AuthUser user, String permission) {
        if (!has(user, permission)) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
    }

    private static void requireAny(AuthUser user, String... permissions) {
        for (String permission : permissions) {
            if (has(user, permission)) {
                return;
            }
        }
        throw new ApiException(ErrorCode.FORBIDDEN);
    }

    private static BigDecimal money(BigDecimal value) {
        return value == null ? BigDecimal.ZERO.setScale(2) : value.setScale(2, RoundingMode.UNNECESSARY);
    }

    private record ItemAmount(
            String code,
            String name,
            String type,
            BigDecimal amount,
            String sourceType
    ) {
    }
}
