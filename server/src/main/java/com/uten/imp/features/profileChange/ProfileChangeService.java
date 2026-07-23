package com.uten.imp.features.profileChange;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.EmergencyContact;
import com.uten.imp.features.org.employee.EmergencyContactRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSensitive;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.features.profileChange.dto.ProfileChangeDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 员工个人信息修改申请服务：
 * <ul>
 *   <li>提交（直改 → 立即生效；需审核 → 创建 pending 批次）</li>
 *   <li>HR 审批（事务内：校验 employee.version → 应用 → 写审计）</li>
 *   <li>HR / 员工双视角列表</li>
 * </ul>
 */
@Service
@RequiredArgsConstructor
public class ProfileChangeService {

    /** 24h 内同字段防重复提交（防骚扰）。 */
    private static final long RECENT_WINDOW_HOURS = 24;

    private final ProfileChangeRepository repo;
    private final EmployeeRepository employeeRepo;
    private final EmployeeSensitiveRepository sensitiveRepo;
    private final EmergencyContactRepository emergencyRepo;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    // ============================================================
    // 员工侧
    // ============================================================

    /**
     * 提交修改申请。一次请求里 direct 字段立即生效，review 字段进 pending 批次。
     * <p>所有字段必须经过 {@link ProfileFieldPolicy#assertSelfEditable(String)} 校验。
     */
    @Transactional
    public ProfileChangeDto.SubmitResponse submit(ProfileChangeDto.SubmitRequest req) {
        AuthUser user = requireStaff();
        UUID employeeId = user.getEmployeeId();
        if (employeeId == null) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前账号未绑定员工档案");
        }
        if (req == null || req.changes() == null || req.changes().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "变更内容不能为空");
        }
        if (req.idemKey() == null || req.idemKey().isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "幂等键不能为空");
        }
        // 幂等键唯一约束兜底（DB 也会拦；早返回）
        Optional<ProfileChangeRequest> existing = repo.findByIdemKey(req.idemKey());
        if (existing.isPresent()) {
            ProfileChangeRequest p = existing.get();
            return new ProfileChangeDto.SubmitResponse(
                    p.getBatchId(), List.of(p.getId()), 1);
        }

        Employee emp = employeeRepo.findById(employeeId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "员工档案不存在"));

        UUID batchId = req.batchId() != null ? req.batchId() : UUID.randomUUID();
        OffsetDateTime now = OffsetDateTime.now();
        OffsetDateTime recentSince = now.minusHours(RECENT_WINDOW_HOURS);
        List<UUID> createdIds = new ArrayList<>();
        int directApplied = 0;

        for (ProfileChangeDto.FieldChange ch : req.changes()) {
            ProfileFieldPolicy.assertSelfEditable(ch.fieldCode());

            String oldValue = readCurrentValue(emp, ch.fieldCode());

            // 24h 内同字段已有 pending/approved/applied 记录 → 拒绝重复提交
            if (ProfileFieldPolicy.isRequiresReview(ch.fieldCode())
                    && repo.countRecentActiveByField(employeeId, ch.fieldCode(), recentSince) > 0) {
                throw new ApiException(ErrorCode.RATE_LIMITED,
                        "24h 内已提交过该字段的修改，请等待处理：" + ch.fieldCode());
            }

            if (ProfileFieldPolicy.isDirectEdit(ch.fieldCode())) {
                // 直改：立即生效
                applyDirectEdit(emp, ch.fieldCode(), ch.newValue());
                directApplied++;
            } else {
                // 需审核：写一行 pending
                ProfileChangeRequest row = new ProfileChangeRequest();
                row.setEmployeeId(employeeId);
                row.setBatchId(batchId);
                row.setFieldCode(ch.fieldCode());
                row.setFieldLabel(ch.fieldLabel() == null ? ch.fieldCode() : ch.fieldLabel());
                row.setFieldGroup(ProfileFieldPolicy.groupOf(ch.fieldCode()));
                row.setOldValueEnc(oldValue);
                row.setNewValueEnc(ch.newValue());
                row.setStatus("pending");
                row.setSubmittedBy(employeeId);
                row.setSubmittedAt(now);
                row.setEmployeeVersion(emp.getVersion());
                row.setIdemKey(req.idemKey() + ":" + ch.fieldCode());   // 同批次多字段不冲突
                repo.save(row);
                createdIds.add(row.getId());
            }
        }

        if (directApplied > 0) {
            emp.setVersion(emp.getVersion() + 1);
            employeeRepo.save(emp);
        }
        tx.bind();
        return new ProfileChangeDto.SubmitResponse(batchId, createdIds, createdIds.size());
    }

    /** 员工自查列表。 */
    @Transactional(readOnly = true)
    public ProfileChangeDto.Page<ProfileChangeDto.MyListItem> myList(int page, int size, String status) {
        UUID userId = requireStaff().getId();
        Pageable pageable = PageRequest.of(Math.max(0, page - 1), Math.min(Math.max(1, size), 100));
        Page<ProfileChangeRequest> p = (status == null || status.isBlank())
                ? repo.findBySubmittedByOrderBySubmittedAtDesc(userId, pageable)
                : repo.findBySubmittedByAndStatusOrderBySubmittedAtDesc(userId, status, pageable);
        List<ProfileChangeDto.MyListItem> items = new ArrayList<>();
        // 折叠为 batch
        java.util.Map<UUID, List<ProfileChangeRequest>> byBatch = new java.util.LinkedHashMap<>();
        for (ProfileChangeRequest r : p.getContent()) {
            byBatch.computeIfAbsent(r.getBatchId(), k -> new ArrayList<>()).add(r);
        }
        for (var e : byBatch.entrySet()) {
            List<ProfileChangeRequest> rs = e.getValue();
            ProfileChangeRequest first = rs.get(0);
            String s = aggregateStatus(rs);
            items.add(new ProfileChangeDto.MyListItem(
                    e.getKey(), s, rs.size(),
                    first.getSubmittedAt(),
                    first.getReviewedAt(),
                    first.getReviewComment(),
                    rs.stream().map(ProfileChangeRequest::getFieldCode).toList(),
                    rs.stream().map(ProfileChangeRequest::getFieldLabel).toList()
            ));
        }
        return new ProfileChangeDto.Page<>(items, page, size, p.getTotalElements(), p.getTotalPages());
    }

    /** 员工自查单批详情。 */
    @Transactional(readOnly = true)
    public ProfileChangeDto.BatchDetail myBatchDetail(UUID batchId) {
        UUID userId = requireStaff().getId();
        List<ProfileChangeRequest> rs = repo.findByBatchId(batchId);
        if (rs.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "申请不存在");
        boolean mine = rs.stream().allMatch(r -> r.getSubmittedBy().equals(userId));
        if (!mine) throw new ApiException(ErrorCode.FORBIDDEN);
        return toBatchDetail(rs);
    }

    /** 员工撤销未审批次。 */
    @Transactional
    public void cancelBatch(UUID batchId) {
        UUID userId = requireStaff().getId();
        List<ProfileChangeRequest> rs = repo.findByBatchIdAndStatus(batchId, "pending");
        if (rs.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "无 pending 批次可撤销");
        boolean mine = rs.stream().allMatch(r -> r.getSubmittedBy().equals(userId));
        if (!mine) throw new ApiException(ErrorCode.FORBIDDEN);
        OffsetDateTime now = OffsetDateTime.now();
        for (ProfileChangeRequest r : rs) {
            r.setStatus("cancelled");
            r.setReviewedAt(now);
            r.setReviewComment("EMPLOYEE_CANCELLED");
        }
        tx.bind();
        repo.saveAll(rs);
    }

    // ============================================================
    // HR 侧
    // ============================================================

    /** HR 队列。 */
    @Transactional(readOnly = true)
    public ProfileChangeDto.Page<ProfileChangeDto.HrListItem> hrList(int page, int size, String status, UUID employeeId) {
        requireHr();
        Pageable pageable = PageRequest.of(Math.max(0, page - 1), Math.min(Math.max(1, size), 100));
        Page<ProfileChangeRequest> p;
        if (employeeId != null) {
            p = (status == null || status.isBlank())
                    ? repo.findByEmployeeIdOrderBySubmittedAtDesc(employeeId, pageable)
                    : repo.findByEmployeeIdAndStatusOrderBySubmittedAtDesc(employeeId, status, pageable);
        } else {
            p = (status == null || status.isBlank() || "pending".equals(status))
                    ? repo.findByStatusOrderBySubmittedAtDesc("pending", pageable)
                    : repo.findAllByOrderBySubmittedAtDesc(pageable);
        }
        List<ProfileChangeDto.HrListItem> items = new ArrayList<>();
        java.util.Map<UUID, List<ProfileChangeRequest>> byBatch = new java.util.LinkedHashMap<>();
        for (ProfileChangeRequest r : p.getContent()) {
            byBatch.computeIfAbsent(r.getBatchId(), k -> new ArrayList<>()).add(r);
        }
        for (var e : byBatch.entrySet()) {
            List<ProfileChangeRequest> rs = e.getValue();
            ProfileChangeRequest first = rs.get(0);
            Employee emp = employeeRepo.findById(first.getEmployeeId()).orElse(null);
            items.add(new ProfileChangeDto.HrListItem(
                    e.getKey(),
                    first.getEmployeeId(),
                    emp == null ? null : emp.getFullName(),
                    emp == null ? null : emp.getCode(),
                    emp == null || emp.getDepartment() == null ? null : emp.getDepartment().getName(),
                    aggregateStatus(rs),
                    rs.size(),
                    rs.stream().map(ProfileChangeRequest::getFieldCode).toList(),
                    first.getSubmittedAt(),
                    first.getReviewedAt(),
                    null
            ));
        }
        return new ProfileChangeDto.Page<>(items, page, size, p.getTotalElements(), p.getTotalPages());
    }

    /** HR 单批详情（含完整 diff）。 */
    @Transactional(readOnly = true)
    public ProfileChangeDto.BatchDetail hrBatchDetail(UUID batchId) {
        requireHr();
        List<ProfileChangeRequest> rs = repo.findByBatchId(batchId);
        if (rs.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "申请不存在");
        return toBatchDetail(rs);
    }

    /** HR 批准 / 驳回。事务内：乐观锁 → 应用字段 → 写审计。 */
    @Transactional
    public ProfileChangeDto.BatchDetail review(UUID batchId, ProfileChangeDto.ReviewAction req) {
        AuthUser reviewer = requireHr();
        UUID reviewerId = reviewer.getId();
        UUID reviewerEmployeeId = reviewer.getEmployeeId();

        if (req == null || req.action() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "审批动作不能为空");
        }
        String action = req.action();
        String comment = req.comment();

        List<ProfileChangeRequest> rs = repo.findByBatchIdAndStatus(batchId, "pending");
        if (rs.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "无可审批批次");
        ProfileChangeRequest first = rs.get(0);
        if (reviewerEmployeeId != null && reviewerEmployeeId.equals(first.getSubmittedBy())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "不能审批自己提交的申请");
        }

        OffsetDateTime now = OffsetDateTime.now();
        switch (action) {
            case "approve" -> {
                Employee emp = employeeRepo.findById(first.getEmployeeId())
                        .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "员工档案不存在"));
                // 乐观锁：所有记录 employee_version 必须等于当前员工 version
                for (ProfileChangeRequest r : rs) {
                    if (!Integer.valueOf(emp.getVersion()).equals(r.getEmployeeVersion())) {
                        throw new ApiException(ErrorCode.CONFLICT, "档案已被他人修改，请刷新后再审");
                    }
                }
                // 应用每条变更
                for (ProfileChangeRequest r : rs) {
                    applyReviewedChange(emp, r);
                    r.setStatus("applied");
                }
                emp.setVersion(emp.getVersion() + 1);
                employeeRepo.save(emp);
            }
            case "reject" -> {
                if (comment == null || comment.isBlank()) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED, "驳回意见必填");
                }
                for (ProfileChangeRequest r : rs) {
                    r.setStatus("rejected");
                }
            }
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知审批动作：" + action);
        }
        for (ProfileChangeRequest r : rs) {
            r.setReviewedBy(reviewerId);
            r.setReviewedAt(now);
            r.setReviewComment(comment);
        }
        tx.bindActor(reviewerId);
        repo.saveAll(rs);
        return toBatchDetail(rs);
    }

    /** 某员工的待审数（员工详情 Hero 后区块用）。 */
    @Transactional(readOnly = true)
    public long pendingCountForEmployee(UUID employeeId) {
        if (!hasReviewPerm()) return 0;
        return repo.countByEmployeeIdAndStatus(employeeId, "pending");
    }

    /** 当前 HR 全局待办数（导航徽章）。 */
    @Transactional(readOnly = true)
    public long pendingCount() {
        if (!hasReviewPerm()) return 0;
        return repo.countByStatus("pending");
    }

    // ============================================================
    // helpers
    // ============================================================

    private AuthUser requireStaff() {
        AuthUser u = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (u.isVisitor()) throw new ApiException(ErrorCode.FORBIDDEN, "仅员工可访问");
        return u;
    }

    private AuthUser requireHr() {
        AuthUser u = requireStaff();
        if (!u.getPermissions().contains("profile:review") && !u.isSuperAdmin()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无 profile:review 权限");
        }
        return u;
    }

    private boolean hasReviewPerm() {
        return currentUser.get()
                .map(u -> u.isSuperAdmin() || u.getPermissions().contains("profile:review"))
                .orElse(false);
    }

    /** 把数据库里的当前值（解密）取出来作为 oldValue。敏感字段走 decrypt。 */
    private String readCurrentValue(Employee emp, String fieldCode) {
        if (fieldCode == null) return null;
        if (ProfileFieldPolicy.isEmergencyContactSubfield(fieldCode)) {
            int idx = ProfileFieldPolicy.emergencyContactIndex(fieldCode);
            String sub = ProfileFieldPolicy.emergencyContactSubfield(fieldCode);
            List<EmergencyContact> list = emergencyRepo.findByEmployeeIdOrderBySortOrderAsc(emp.getId());
            if (idx < 0 || idx >= list.size()) return null;
            EmergencyContact ec = list.get(idx);
            return switch (sub) {
                case "name" -> ec.getName();
                case "relationship" -> ec.getRelationship();
                case "phone" -> ec.getPhoneEnc() == null ? null : safeDecrypt(ec.getPhoneEnc());
                default -> null;
            };
        }
        return switch (fieldCode) {
            case ProfileFieldPolicy.Field.FULL_NAME -> emp.getFullName();
            case ProfileFieldPolicy.Field.ETHNICITY -> emp.getEthnicity();
            case ProfileFieldPolicy.Field.POLITICAL_STATUS -> emp.getPoliticalStatus();
            case ProfileFieldPolicy.Field.MARITAL_STATUS -> emp.getMaritalStatus();
            case ProfileFieldPolicy.Field.HUJI_ADDRESS -> emp.getHujiAddress();
            case ProfileFieldPolicy.Field.RESIDENCE_ADDRESS -> emp.getResidenceAddress();
            case ProfileFieldPolicy.Field.OFFICE_PHONE -> emp.getOfficePhone();
            case ProfileFieldPolicy.Field.EMAIL -> emp.getEmail();
            case ProfileFieldPolicy.Field.SEAT_NO -> emp.getSeatNo();
            case ProfileFieldPolicy.Field.PHONE -> {
                EmployeeSensitive s = sensitiveRepo.findByEmployeeId(emp.getId()).orElse(null);
                yield s == null || s.getPhoneEnc() == null ? null : safeDecrypt(s.getPhoneEnc());
            }
            default -> null;
        };
    }

    /** 直改：直接写 employees / employee_sensitive / emergency_contacts。 */
    private void applyDirectEdit(Employee emp, String fieldCode, String newValue) {
        if (ProfileFieldPolicy.isEmergencyContactSubfield(fieldCode)) {
            int idx = ProfileFieldPolicy.emergencyContactIndex(fieldCode);
            String sub = ProfileFieldPolicy.emergencyContactSubfield(fieldCode);
            List<EmergencyContact> list = emergencyRepo.findByEmployeeIdOrderBySortOrderAsc(emp.getId());
            if (idx >= list.size()) throw new ApiException(ErrorCode.VALIDATION_FAILED, "紧急联系人不存在");
            EmergencyContact ec = list.get(idx);
            switch (sub) {
                case "name" -> ec.setName(newValue);
                case "relationship" -> ec.setRelationship(newValue);
                case "phone" -> ec.setPhoneEnc(safeEncrypt(newValue));
                default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知紧急联系人字段：" + sub);
            }
            emergencyRepo.save(ec);
            return;
        }
        switch (fieldCode) {
            case ProfileFieldPolicy.Field.ETHNICITY -> emp.setEthnicity(newValue);
            case ProfileFieldPolicy.Field.POLITICAL_STATUS -> emp.setPoliticalStatus(newValue);
            case ProfileFieldPolicy.Field.MARITAL_STATUS -> emp.setMaritalStatus(newValue);
            case ProfileFieldPolicy.Field.RESIDENCE_ADDRESS -> emp.setResidenceAddress(newValue);
            case ProfileFieldPolicy.Field.OFFICE_PHONE -> emp.setOfficePhone(newValue);
            case ProfileFieldPolicy.Field.EMAIL -> emp.setEmail(newValue);
            case ProfileFieldPolicy.Field.SEAT_NO -> emp.setSeatNo(newValue);
            case ProfileFieldPolicy.Field.PHONE -> {
                EmployeeSensitive s = sensitiveRepo.findByEmployeeId(emp.getId())
                        .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "敏感信息不存在"));
                s.setPhoneEnc(safeEncrypt(newValue));
                sensitiveRepo.save(s);
            }
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "非直改字段：" + fieldCode);
        }
    }

    /** 审核通过后应用字段变更。 */
    private void applyReviewedChange(Employee emp, ProfileChangeRequest row) {
        String newValue = row.getNewValueEnc();
        String fieldCode = row.getFieldCode();
        if (ProfileFieldPolicy.isEmergencyContactSubfield(fieldCode)) {
            int idx = ProfileFieldPolicy.emergencyContactIndex(fieldCode);
            String sub = ProfileFieldPolicy.emergencyContactSubfield(fieldCode);
            List<EmergencyContact> list = emergencyRepo.findByEmployeeIdOrderBySortOrderAsc(emp.getId());
            if (idx >= list.size()) throw new ApiException(ErrorCode.VALIDATION_FAILED, "紧急联系人不存在");
            EmergencyContact ec = list.get(idx);
            switch (sub) {
                case "name" -> ec.setName(newValue);
                case "relationship" -> ec.setRelationship(newValue);
                case "phone" -> ec.setPhoneEnc(safeEncrypt(newValue));
            }
            emergencyRepo.save(ec);
            return;
        }
        switch (fieldCode) {
            case ProfileFieldPolicy.Field.FULL_NAME -> emp.setFullName(newValue);
            case ProfileFieldPolicy.Field.HUJI_ADDRESS -> emp.setHujiAddress(newValue);
            case ProfileFieldPolicy.Field.PHONE -> {
                EmployeeSensitive s = sensitiveRepo.findByEmployeeId(emp.getId())
                        .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "敏感信息不存在"));
                s.setPhoneEnc(safeEncrypt(newValue));
                sensitiveRepo.save(s);
            }
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "不支持的审核字段：" + fieldCode);
        }
    }

    private String safeDecrypt(String cipher) {
        try {
            return tx.decrypt(cipher);
        } catch (Exception e) {
            return null;
        }
    }

    private String safeEncrypt(String plain) {
        if (plain == null || plain.isBlank()) return null;
        return tx.encrypt(plain);
    }

    /** 同批次多字段整体状态：applied / approved / rejected / pending / cancelled。 */
    private String aggregateStatus(List<ProfileChangeRequest> rs) {
        boolean anyApplied = rs.stream().anyMatch(r -> "applied".equals(r.getStatus()));
        if (anyApplied) return "applied";
        boolean anyApproved = rs.stream().anyMatch(r -> "approved".equals(r.getStatus()));
        if (anyApproved) return "approved";
        boolean anyRejected = rs.stream().anyMatch(r -> "rejected".equals(r.getStatus()));
        if (anyRejected) return "rejected";
        boolean anyCancelled = rs.stream().anyMatch(r -> "cancelled".equals(r.getStatus()));
        if (anyCancelled) return "cancelled";
        return "pending";
    }

    private ProfileChangeDto.BatchDetail toBatchDetail(List<ProfileChangeRequest> rs) {
        ProfileChangeRequest first = rs.get(0);
        Employee emp = employeeRepo.findById(first.getEmployeeId()).orElse(null);
        List<ProfileChangeDto.Item> items = new ArrayList<>();
        for (ProfileChangeRequest r : rs) {
            String oldVal = r.getOldValueEnc();
            String newVal = r.getNewValueEnc();
            boolean encrypted = ProfileFieldPolicy.isEmergencyContactSubfield(r.getFieldCode())
                    || ProfileFieldPolicy.Field.PHONE.equals(r.getFieldCode());
            String oldOut = encrypted && oldVal != null && oldVal.contains(":") ? safeDecrypt(oldVal) : oldVal;
            String newOut = encrypted && newVal != null && newVal.contains(":") ? safeDecrypt(newVal) : newVal;
            items.add(new ProfileChangeDto.Item(
                    r.getId(), r.getBatchId(), r.getFieldCode(), r.getFieldLabel(), r.getFieldGroup(),
                    oldOut, newOut,
                    r.getStatus(),
                    r.getSubmittedBy(),
                    employeeRepo.findById(r.getSubmittedBy()).map(Employee::getFullName).orElse(null),
                    r.getSubmittedAt(),
                    r.getReviewedBy(),
                    r.getReviewedBy() == null ? null
                            : employeeRepo.findById(r.getReviewedBy()).map(Employee::getFullName).orElse(null),
                    r.getReviewedAt(), r.getReviewComment(), r.getEmployeeVersion()
            ));
        }
        return new ProfileChangeDto.BatchDetail(
                first.getBatchId(),
                first.getEmployeeId(),
                emp == null ? null : emp.getFullName(),
                emp == null ? null : emp.getCode(),
                aggregateStatus(rs),
                rs.size(), items,
                first.getSubmittedAt(),
                employeeRepo.findById(first.getSubmittedBy()).map(Employee::getFullName).orElse(null),
                first.getReviewedAt(),
                first.getReviewedBy() == null ? null
                        : employeeRepo.findById(first.getReviewedBy()).map(Employee::getFullName).orElse(null),
                first.getReviewComment()
        );
    }
}