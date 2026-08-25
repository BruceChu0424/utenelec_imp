package com.uten.imp.features.org.employee;

import com.uten.imp.application.port.AttachmentAccessPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentLevelPolicy;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.dto.EmployeeDetail;
import com.uten.imp.features.org.employee.dto.NestedDtos;
import com.uten.imp.features.org.employee.dto.OffboardRequest;
import com.uten.imp.features.org.employee.dto.OnboardingRequest;
import com.uten.imp.features.org.employee.dto.RenewContractRequest;
import com.uten.imp.features.org.employee.dto.SetAvatarRequest;
import com.uten.imp.features.org.employee.dto.TransferRequest;
import com.uten.imp.features.org.employee.dto.UpdateEmployeeRequest;
import com.uten.imp.features.org.position.Position;
import com.uten.imp.features.org.position.PositionRepository;
import com.uten.imp.responsibility.DataHandoverService;
import com.uten.imp.responsibility.dto.DataHandoverAction;
import com.uten.imp.responsibility.dto.DataHandoverPreview;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.common.util.Strings.isBlank;

/** 员工档案写操作：HR 编辑（含敏感/薪资重写）、调岗/离职/转正/删除、任职轨迹查询。 */
@Service
@RequiredArgsConstructor
public class EmployeeCommandService {

    private static final Set<String> REQUIRED_OFFBOARDING_CHECKLIST = Set.of(
            "ACCESS_CARD_RETURNED",
            "COMPANY_ASSETS_ACCOUNTED",
            "ACCOUNT_DISABLE_ACKNOWLEDGED",
            "SOCIAL_BENEFITS_ARRANGED");
    private static final Map<String, String> OFFBOARDING_CHECKLIST_LABELS = Map.of(
            "ACCESS_CARD_RETURNED", "门禁卡归还已人工确认",
            "COMPANY_ASSETS_ACCOUNTED", "公司资产盘点已人工确认",
            "ACCOUNT_DISABLE_ACKNOWLEDGED", "账号停用安排已知悉",
            "SOCIAL_BENEFITS_ARRANGED", "社保公积金安排已人工确认");

    private final EmployeeRepository empRepo;
    private final EmployeeSensitiveRepository sensitiveRepo;
    private final EmployeePiiWriter piiWriter;
    private final EmployeeCompensationRepository compensationRepo;
    private final EmployeeCredentialRepository credentialRepo;
    private final EmployeeEducationRepository educationRepo;
    private final EmployeeContractRepository contractRepo;
    private final AttachmentAccessPort attachmentAccess;
    private final EmploymentHistoryRepository historyRepo;
    private final DepartmentRepository deptRepo;
    private final PositionRepository positionRepo;
    private final UserAccountRepository userRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final EmployeeQueryService queryService;
    private final EmployeeSensitiveWritePolicy sensitiveWritePolicy;
    private final EmployeeVehiclePhoneService vehiclePhoneService;
    private final EmployeeLoginAccountSync loginAccountSync;
    private final DataHandoverService dataHandoverService;

    // ===== 更新 =====
    /** 编辑员工档案：状态机收口——离职/复职禁止在此直改，必须走 /offboard、/rehire 以保证账号冻结与任职轨迹闭环；每次保存递增 version，使在途申请审批时 409 防丢更新。 */
    @PreAuthorize("hasAuthority('employee:edit')")
    @Transactional
    public EmployeeDetail update(UUID id, UpdateEmployeeRequest r) {
        sensitiveWritePolicy.assertUpdateAllowed(r);
        tx.bind();
        Employee e = queryService.requireEmployee(id);
        assertSensitiveUpdateAllowed(id, r);
        assertDepartmentChangeUsesTransfer(e, r.departmentId());
        assertLifecycleFieldsUseDedicatedCommands(e, r);
        if (nn(r.fullName())) e.setFullName(r.fullName());
        if (nn(r.gender())) e.setGender(r.gender());
        if (nn(r.ethnicity())) e.setEthnicity(r.ethnicity());
        // 出生日期/政治面貌/婚姻状况/户籍地址/居住地址/办公电话/邮箱 已迁入 sensitive 加密（见 updateSensitive）。
        if (nn(r.birthDate())) e.setBirthMonthDay(
                EmployeeOnboardingService.birthMonthDayOf(r.birthDate()));
        if (r.supervisorId() != null) e.setSupervisor(empRepo.findById(r.supervisorId())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "直属上级不存在")));
        if (nn(r.workLocation())) e.setWorkLocation(r.workLocation());
        if (nn(r.seatNo())) e.setSeatNo(r.seatNo());
        if (nn(r.attendanceGroup())) e.setAttendanceGroup(r.attendanceGroup());
        if (nn(r.paperArchiveNo())) e.setPaperArchiveNo(r.paperArchiveNo());
        if (nn(r.status())) {
            // 状态机收口：离职必须走 /offboard（账号冻结+任职记录+在途申请驳回），
            // 离职员工回在职必须走 /rehire（账号启用+任职记录），不允许编辑直改绕过闭环。
            if ("resigned".equals(r.status()) && !"resigned".equals(e.getStatus())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "请将员工通过「离职办理」流程置为离职，以保证账号冻结与任职记录完整");
            }
            if ("resigned".equals(e.getStatus()) && !"resigned".equals(r.status())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "该员工已离职，请通过「复职」恢复在职状态");
            }
            e.setStatus(r.status());
        }
        if (nn(r.employmentType())) e.setEmploymentType(r.employmentType());
        if (r.confirmedAt() != null) e.setConfirmedAt(r.confirmedAt());
        e.setVersion(e.getVersion() + 1);   // 乐观锁：HR 直改使在途申请审批时 409（防丢更新）
        empRepo.save(e);

        updateSensitive(e, r);
        updateCompensation(id, r);
        replaceCertificates(e, r);
        replaceEducations(e, r);
        // 车辆 / 备用手机号（非 null 整体替换）—— ADR-021
        if (r.vehicles() != null) vehiclePhoneService.replaceVehicles(e, r.vehicles());
        if (r.phones() != null) vehiclePhoneService.replacePhones(e, r.phones());
        return queryService.detail(id);
    }

    /** 证书整体替换（非 null 才动；空数组 = 清空）。 */
    private void replaceCertificates(Employee e, UpdateEmployeeRequest r) {
        if (r.certificates() == null) return;
        credentialRepo.deleteByEmployeeId(e.getId());
        for (OnboardingRequest.CredentialInput ci : r.certificates()) {
            EmployeeCredential cred = new EmployeeCredential();
            cred.setEmployee(e);
            cred.setType(ci.type());
            cred.setName(ci.name());
            cred.setCertNo(ci.certNo());
            cred.setIssuedAt(ci.issuedAt());
            cred.setExpiresAt(ci.expiresAt());
            credentialRepo.save(cred);
        }
    }

    /** 学历整体替换（非 null 才动；空数组 = 清空）。 */
    private void replaceEducations(Employee e, UpdateEmployeeRequest r) {
        if (r.educations() == null) return;
        educationRepo.deleteByEmployeeId(e.getId());
        for (OnboardingRequest.EducationInput ei : r.educations()) {
            EmployeeEducation edu = new EmployeeEducation();
            edu.setEmployee(e);
            edu.setDegree(ei.degree());
            edu.setSchool(ei.school());
            edu.setMajor(ei.major());
            edu.setStartDate(ei.startDate());
            edu.setEndDate(ei.endDate());
            educationRepo.save(edu);
        }
    }

    private void updateSensitive(Employee employee, UpdateEmployeeRequest r) {
        boolean writesPii = EmployeeSensitiveWritePolicy.hasPiiWrite(r);
        boolean writesExtra = hasExtraPiiWrite(r);
        if (!writesPii && !writesExtra) {
            return;
        }
        UUID id = employee.getId();
        EmployeeSensitive s = sensitiveRepo.findByEmployeeId(id).orElseGet(() -> {
            EmployeeSensitive ns = new EmployeeSensitive();
            ns.setEmployeeId(id);
            return ns;
        });
        // employee:pii:edit 层：身份证/手机/银行/备用号（写敏感表）。身份证改动顺带派生生日与性别。
        if (writesPii) {
            if (!isBlank(r.idNumber())) {
                piiWriter.applyIdentity(s, id, employee.getIdType(), r.idNumber());
                if ("身份证".equals(employee.getIdType())) {
                    String normalized = IdCardUtil.normalize(r.idNumber());
                    LocalDate derived = IdCardUtil.birthDate(normalized);
                    piiWriter.applyBirthDate(s, derived);
                    employee.setBirthMonthDay(EmployeeOnboardingService.birthMonthDayOf(derived));
                    employee.setGender(IdCardUtil.gender(normalized));
                }
            }
            if (!isBlank(r.phone())) {
                piiWriter.applyPhone(s, r.phone());
                // 登录账号 = 手机号：HR 直改手机号必须同步登录账号并踢会话（ADR-021 §三）
                loginAccountSync.syncLoginAccount(id, com.uten.imp.common.util.ChinaMobileNumber
                        .normalize(r.phone()).orElseThrow());
            }
            if (!isBlank(r.bankAccount())) s.setBankAccountEnc(tx.encrypt(r.bankAccount()));
            if (!isBlank(r.bankBranch())) s.setBankBranchEnc(tx.encrypt(r.bankBranch()));
        }
        // employee:edit 层（V282 迁入加密）：地址/邮箱/出生日期/婚姻/政治面貌/办公电话。
        // 编辑权限沿用原 employee:edit（不要求 pii:edit），仅存储改为加密。
        if (r.birthDate() != null) {
            piiWriter.applyBirthDate(s, r.birthDate());
            employee.setBirthMonthDay(EmployeeOnboardingService.birthMonthDayOf(r.birthDate()));
        }
        if (!isBlank(r.politicalStatus())) piiWriter.applyPoliticalStatus(s, r.politicalStatus());
        if (!isBlank(r.maritalStatus())) piiWriter.applyMaritalStatus(s, r.maritalStatus());
        if (!isBlank(r.hujiAddress())) piiWriter.applyHujiAddress(s, r.hujiAddress());
        if (!isBlank(r.residenceAddress())) piiWriter.applyResidenceAddress(s, r.residenceAddress());
        if (!isBlank(r.officePhone())) piiWriter.applyOfficePhone(s, r.officePhone());
        if (!isBlank(r.email())) piiWriter.applyEmail(s, r.email());
        sensitiveRepo.save(s);
    }

    /** 是否触及 V282 迁入加密的扩展字段（employee:edit 层，非 pii:edit）。 */
    private static boolean hasExtraPiiWrite(UpdateEmployeeRequest r) {
        return r != null
                && (r.birthDate() != null
                || !isBlank(r.politicalStatus())
                || !isBlank(r.maritalStatus())
                || !isBlank(r.hujiAddress())
                || !isBlank(r.residenceAddress())
                || !isBlank(r.officePhone())
                || !isBlank(r.email()));
    }

    /** HR may maintain normal employees, but encrypted PII/compensation of a super admin is immutable here. */
    private void assertSensitiveUpdateAllowed(UUID employeeId, UpdateEmployeeRequest r) {
        boolean changesSensitive = EmployeeSensitiveWritePolicy.hasPiiWrite(r)
                || EmployeeSensitiveWritePolicy.hasCompensationWrite(r);
        if (!changesSensitive) {
            return;
        }
        userRepo.findByEmployeeId(employeeId).ifPresent(account -> {
            if (account.isSuperAdmin()) {
                throw new ApiException(ErrorCode.FORBIDDEN, "禁止通过员工管理修改超级管理员的敏感信息");
            }
        });
    }

    private void updateCompensation(UUID id, UpdateEmployeeRequest r) {
        if (!EmployeeSensitiveWritePolicy.hasCompensationWrite(r)) {
            return;
        }
        EmployeeCompensation c = compensationRepo.findByEmployeeId(id).orElseGet(() -> {
            EmployeeCompensation nc = new EmployeeCompensation();
            nc.setEmployeeId(id);
            return nc;
        });
        if (!isBlank(r.baseSalary())) c.setBaseSalaryEnc(tx.encrypt(r.baseSalary()));
        if (!isBlank(r.perfSalary())) c.setPerfSalaryEnc(tx.encrypt(r.perfSalary()));
        if (!isBlank(r.socialInsuranceBase())) c.setSocialInsuranceBaseEnc(tx.encrypt(r.socialInsuranceBase()));
        if (!isBlank(r.housingFundBase())) c.setHousingFundBaseEnc(tx.encrypt(r.housingFundBase()));
        if (!isBlank(r.allowanceStandard())) c.setAllowanceStandardEnc(tx.encrypt(r.allowanceStandard()));
        if (!isBlank(r.socialInsuranceLocation())) c.setSocialInsuranceLocation(r.socialInsuranceLocation());
        compensationRepo.save(c);
    }

    // ===== 调岗 / 离职 / 转正 =====

    /**
     * 高危操作保护（离职/复职/删除会联动登录账号）：
     * ① 目标员工绑定超管账号 → 拒绝（防止把引导 admin 的账号停掉，全站失去管理入口）；
     * ② 操作人对自己执行 → 拒绝（防止 HR 误把自己账号冻结）。
     */
    private void assertAccountOperationAllowed(UUID employeeId) {
        assertAccountOperationAllowed(
                employeeId, userRepo.findByEmployeeId(employeeId).orElse(null));
    }

    private void assertAccountOperationAllowed(
            UUID employeeId, UserAccount lockedAccount) {
        currentUser.get().ifPresent(u -> {
            if (employeeId.equals(u.getEmployeeId())) {
                throw new ApiException(ErrorCode.FORBIDDEN, "不能对本人执行该操作");
            }
        });
        if (lockedAccount != null && lockedAccount.isSuperAdmin()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "该员工绑定超级管理员账号，禁止此操作");
        }
    }

    @PreAuthorize("hasAuthority('employee:transfer')")
    @Transactional
    public void transfer(UUID id, TransferRequest req) {
        tx.bind();
        Employee e = queryService.requireEmployee(id);
        if ("resigned".equals(e.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT, "该员工已离职，不可调岗");
        }
        assertEffectiveDate(e, req.effectiveDate());
        Department to = requireEmployeeHostDepartment(req.toDepartmentId());
        Position toPos = req.toPositionId() == null
                ? null
                : requireActivePositionInDepartment(req.toPositionId(), to.getId());

        UUID fromDepartmentId = e.getDepartment() == null
                ? null
                : e.getDepartment().getId();
        boolean departmentChanged = !to.getId().equals(fromDepartmentId);
        EmploymentHistory h = new EmploymentHistory();
        h.setEmployee(e);
        h.setEventType("transfer");
        h.setFromDepartmentId(fromDepartmentId);
        h.setToDepartmentId(to.getId());
        h.setFromPositionId(e.getPosition() == null ? null : e.getPosition().getId());
        h.setToPositionId(toPos == null ? null : toPos.getId());
        h.setEventDate(req.effectiveDate());
        h.setRemark(req.remark());
        historyRepo.save(h);

        if (departmentChanged) clearManagedDepartments(e);
        e.setDepartment(to);
        e.setPosition(toPos);
        if (req.supervisorId() != null) {
            e.setSupervisor(empRepo.findById(req.supervisorId()).orElse(null));
        }
        e.setVersion(e.getVersion() + 1);   // 乐观锁：调岗也算档案变更
        empRepo.save(e);
    }

    @PreAuthorize("hasAuthority('employee:offboard')")
    @Transactional(isolation = Isolation.REPEATABLE_READ)
    public void offboard(UUID id, OffboardRequest req) {
        tx.bind();
        tx.bindProfileChangeSnapshotCodecV1();
        assertAccountOperationAllowed(id);
        Employee employee = queryService.requireEmployee(id);
        String resignType = normalizeResignType(req.resignType());
        String reason = req.reason() == null ? "" : req.reason().trim();
        if (reason.isEmpty() || reason.length() > 2000) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "离职原因须为 1–2000 个字符");
        }
        Set<String> checklistCodes = requireCompleteOffboardingChecklist(
                req.confirmedChecklistCodes());
        assertEffectiveDate(employee, req.effectiveDate());
        String handoverReason = !isBlank(req.handoverReason())
                ? req.handoverReason().trim()
                : reason;

        boolean replayed = dataHandoverService.beginOffboarding(
                req.requestId(), id, req.successorEmployeeId(),
                req.effectiveDate(), resignType, reason,
                handoverReason, checklistCodes);
        if (replayed) return;
        if ("resigned".equals(employee.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT, "该员工已离职");
        }

        // beginOffboarding already holds the global coordinator and canonical participants.
        employee.setStatus("resigned");
        employee.setVersion(employee.getVersion() + 1);
        empRepo.saveAndFlush(employee);

        DataHandoverPreview handover = dataHandoverService.previewOffboarding(
                id, req.successorEmployeeId());
        if (handover.hasBlockers()) {
            String blockers = handover.items().stream()
                    .filter(item -> item.action() == DataHandoverAction.BLOCKING
                            && item.count() > 0)
                    .map(item -> item.label() + " " + item.count() + " 项")
                    .reduce((left, right) -> left + "；" + right)
                    .orElse("存在未处理的数据交接阻塞项");
            throw new ApiException(
                    ErrorCode.CONFLICT, "离职前需完成数据交接：" + blockers);
        }
        if (handover.requiresTarget() && req.successorEmployeeId() == null) {
            throw new ApiException(
                    ErrorCode.CONFLICT, "该员工仍有未交接责任数据，请选择默认接手人");
        }

        Map<String, Long> handoverSummary = dataHandoverService.executeOffboarding(
                req.requestId(), id, req.successorEmployeeId(),
                handoverReason, req.effectiveDate());
        // Defensive idempotent fallback for a zero-target/zero-business-data departure.
        dataHandoverService.cleanupDepartingEmployee(id);

        EmploymentHistory history = new EmploymentHistory();
        history.setEmployee(employee);
        history.setEventType("resign");
        history.setFromDepartmentId(employee.getDepartment() == null
                ? null : employee.getDepartment().getId());
        history.setEventDate(req.effectiveDate());
        history.setRemark(offboardingHistoryRemark(
                resignType, reason, req.requestId(), checklistCodes));
        historyRepo.save(history);

        // Account disablement is last; any earlier failure rolls back the status, transfers,
        // permissions, history, and this account mutation together.
        userRepo.findByEmployeeId(id).ifPresent(account -> {
            account.setStatus("disabled");
            account.setRemoteAccess(false);
            account.setMustChangePassword(true);
            account.setTempPasswordExpiresAt(null);
            userRepo.save(account);
            refreshTokenRepo.revokeAllByUserId(account.getId());
        });
        dataHandoverService.completeOffboarding(req.requestId(), handoverSummary);
    }

    private void assertEffectiveDate(Employee employee, LocalDate effectiveDate) {
        if (effectiveDate.isAfter(BusinessTime.today())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "生效日期不能晚于今天");
        }
        if (employee.getHireDate() != null
                && effectiveDate.isBefore(employee.getHireDate())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "生效日期不能早于员工入职日期");
        }
        historyRepo.findFirstByEmployeeIdOrderByEventDateDescCreatedAtDesc(employee.getId())
                .filter(latest -> latest.getEventDate().isAfter(effectiveDate))
                .ifPresent(latest -> {
                    throw new ApiException(
                            ErrorCode.VALIDATION_FAILED,
                            "生效日期不能早于最近一次任职事件日期 " + latest.getEventDate());
                });
    }

    @PreAuthorize("hasAuthority('employee:confirm')")
    @Transactional
    public void confirm(UUID id, LocalDate confirmedDate) {
        tx.bind();
        Employee e = queryService.requireEmployee(id);
        if (!"probation".equals(e.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT, "仅试用期员工可转正");
        }
        LocalDate date = confirmedDate == null ? BusinessTime.today() : confirmedDate;
        if (date.isAfter(BusinessTime.today())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "转正日期不能晚于今天");
        }
        if (e.getHireDate() != null && date.isBefore(e.getHireDate())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "转正日期不能早于入职日期");
        }
        e.setStatus("active");
        e.setConfirmedAt(date);
        e.setVersion(e.getVersion() + 1);   // 乐观锁：转正也是档案变更
        empRepo.save(e);

        // 任职轨迹：转正事件（新增事件类型），时间线可见
        EmploymentHistory h = new EmploymentHistory();
        h.setEmployee(e);
        h.setEventType("confirm");
        h.setFromDepartmentId(e.getDepartment() == null ? null : e.getDepartment().getId());
        h.setToDepartmentId(e.getDepartment() == null ? null : e.getDepartment().getId());
        h.setEventDate(date);
        h.setRemark("转正");
        historyRepo.save(h);
    }

    /**
     * 更换手机号（ADR-021 §三）：手机号 = 登录账号。
     * 单事务内：格式/唯一性校验 → 加密重写 + HMAC → 登录账号同步 + 吊销 refresh（强制重登）。
     */
    @PreAuthorize("hasAuthority('employee:pii:edit')")
    @Transactional
    public void changePhone(UUID id, String newPhone) {
        tx.bind();
        Employee e = queryService.requireEmployee(id);
        // 超管账号的敏感信息同样禁止经此入口修改（与 update 一致）
        userRepo.findByEmployeeId(id).ifPresent(account -> {
            if (account.isSuperAdmin()) {
                throw new ApiException(ErrorCode.FORBIDDEN, "禁止通过员工管理修改超级管理员的手机号");
            }
        });
        String normalized = com.uten.imp.common.util.ChinaMobileNumber.normalize(newPhone)
                .orElseThrow(() -> new ApiException(
                        ErrorCode.VALIDATION_FAILED, "中国大陆手机号格式不正确"));
        String hash = tx.hmac(normalized);
        if (hash != null && sensitiveRepo.existsByPhoneHashAndEmployeeIdNot(hash, e.getId())) {
            throw new ApiException(ErrorCode.CONFLICT, "该手机号已被其他员工使用");
        }
        EmployeeSensitive s = sensitiveRepo.findByEmployeeId(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "敏感信息不存在"));
        piiWriter.applyPhone(s, normalized);
        sensitiveRepo.save(s);
        e.setVersion(e.getVersion() + 1);
        empRepo.save(e);
        // 同步登录账号并吊销会话；员工无登录账号时仅改档案
        loginAccountSync.syncLoginAccount(id, normalized);
    }

    /** 复职：离职员工恢复在职，写一条 rehire 任职记录并重新启用登录账号。 */
    @PreAuthorize("hasAuthority('employee:rehire')")
    @Transactional
    public void rehire(UUID id) {
        tx.bind();
        Employee e = empRepo.findByIdForUpdate(id)
                .filter(employee -> !employee.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "员工不存在"));
        UserAccount lockedAccount = userRepo.findIdByEmployeeId(id)
                .map(accountId -> userRepo.findByIdForUpdate(accountId)
                        .orElseThrow(() -> new ApiException(
                                ErrorCode.CONFLICT, "员工账号在复职期间已变化")))
                .orElse(null);
        if (lockedAccount != null
                && !Objects.equals(id, lockedAccount.getEmployeeId())) {
            throw new ApiException(ErrorCode.CONFLICT, "员工账号绑定已变化，请刷新后重试");
        }
        assertAccountOperationAllowed(id, lockedAccount);
        if (!"resigned".equals(e.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT, "仅离职员工可复职");
        }
        EmploymentHistory h = new EmploymentHistory();
        h.setEmployee(e);
        h.setEventType("rehire");
        h.setFromDepartmentId(e.getDepartment() == null ? null : e.getDepartment().getId());
        h.setToDepartmentId(e.getDepartment() == null ? null : e.getDepartment().getId());
        h.setEventDate(BusinessTime.today());
        h.setRemark("复职");
        historyRepo.save(h);

        e.setStatus("active");
        e.setVersion(e.getVersion() + 1);   // 乐观锁：复职也是档案变更
        empRepo.save(e);

        // 新任职不恢复旧个人授权/外网能力；旧密码仅可进入强制改密流程。
        if (lockedAccount != null) {
            lockedAccount.setStatus("active");
            lockedAccount.setRemoteAccess(false);
            lockedAccount.setMustChangePassword(true);
            lockedAccount.setTempPasswordExpiresAt(null);
            userRepo.save(lockedAccount);
            refreshTokenRepo.revokeAllByUserId(lockedAccount.getId());
        }
    }

    /** 续签/补录合同：signOrder 取该员工现有最大序号 +1；离职员工不可续签。 */
    @PreAuthorize("hasAuthority('employee:contract_renew')")
    @Transactional
    public void renewContract(UUID employeeId, RenewContractRequest req) {
        tx.bind();
        Employee e = queryService.requireEmployee(employeeId);
        if ("resigned".equals(e.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT, "该员工已离职，不可续签合同");
        }
        if (req.startDate() != null && req.endDate() != null
                && req.endDate().isBefore(req.startDate())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "合同结束日期不能早于开始日期");
        }
        int nextOrder = contractRepo.findByEmployeeIdOrderBySignOrderAsc(employeeId).stream()
                .mapToInt(EmployeeContract::getSignOrder).max().orElse(0) + 1;
        EmployeeContract c = new EmployeeContract();
        c.setEmployee(e);
        c.setContractType(req.contractType() == null ? "fixed" : req.contractType());
        c.setStartDate(req.startDate() == null ? BusinessTime.today() : req.startDate());
        c.setEndDate(req.endDate());
        c.setProbationMonths(req.probationMonths());
        c.setSignOrder(nextOrder);
        contractRepo.save(c);
        e.setVersion(e.getVersion() + 1);   // 乐观锁：合同变更也是档案变更
        empRepo.save(e);
    }

    /**
     * 设置员工头像：把指定图片附件（须归属该员工、CLEAN）标为头像，并冗余 storage_key 到
     * employees.avatar_storage_key（供花名册列表直接取，免 N+1）。同员工仅一张头像。
     */
    @PreAuthorize("hasAuthority('employee:avatar_edit')")
    @Transactional
    public void setAvatar(UUID employeeId, SetAvatarRequest req) {
        tx.bind();
        Employee e = queryService.requireEmployee(employeeId);
        String storageKey = attachmentAccess.selectAvatar(
                EmployeeAttachmentAccessPolicy.OWNER_TYPE, employeeId, req.attachmentId());
        e.setAvatarStorageKey(storageKey);
        e.setVersion(e.getVersion() + 1);
        empRepo.save(e);
    }

    // 注：禁止删除员工——不再提供 delete(...) 能力。员工离职走 offboard(...)（status='resigned'
    // 永久留存），任何人都不能从档案中删除员工。原 assertArchiveAllowed 护栏一并下线。

    @PreAuthorize("hasAuthority('employee:view')")
    @Transactional(readOnly = true)
    public List<NestedDtos.EmploymentHistoryDto> history(UUID id) {
        queryService.requireEmployee(id);
        return historyRepo.findByEmployeeIdOrderByEventDateDesc(id).stream()
                .map(queryService::toHistory).toList();
    }

    private void clearManagedDepartments(Employee employee) {
        List<Department> managed = deptRepo.findByManagerId(employee.getId());
        if (managed.isEmpty()) return;
        managed.forEach(department -> department.setManager(null));
        deptRepo.saveAll(managed);
    }

    private Department requireEmployeeHostDepartment(UUID departmentId) {
        Department department = deptRepo.findById(departmentId)
                .filter(candidate -> !candidate.isDeleted())
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND,
                        "目标部门不存在或已停用"));
        if (!DepartmentLevelPolicy.canHostEmployees(department.getLevel())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "公司和决策层节点不能接收员工");
        }
        return department;
    }

    private Position requireActivePositionInDepartment(
            UUID positionId,
            UUID departmentId) {
        return positionRepo
                .findByIdAndDepartmentIdAndDeletedFalse(positionId, departmentId)
                .orElseThrow(() -> new ApiException(
                        ErrorCode.CONFLICT,
                        "岗位不存在、已停用或不属于目标部门"));
    }

    static void assertLifecycleFieldsUseDedicatedCommands(
            Employee employee,
            UpdateEmployeeRequest request) {
        String requestedStatus = request.status();
        if (nn(requestedStatus)
                && !Objects.equals(employee.getStatus(), requestedStatus)) {
            if ("resigned".equals(requestedStatus)) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "员工离职请使用「离职办理」功能，以完成账号冻结和任职记录");
            }
            if ("resigned".equals(employee.getStatus())) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "离职员工恢复在职请使用「复职」功能，以恢复账号和任职记录");
            }
            if ("probation".equals(employee.getStatus())
                    && "active".equals(requestedStatus)) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "试用员工转为在职请使用「转正」功能，以记录转正日期");
            }
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "员工状态变更请使用员工详情中的转正、离职或复职专用功能");
        }

        if (request.confirmedAt() != null
                && !Objects.equals(employee.getConfirmedAt(), request.confirmedAt())) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "设置或修改转正日期请使用「转正」功能");
        }

        UUID currentPositionId = employee.getPosition() == null
                ? null
                : employee.getPosition().getId();
        if (request.positionId() != null
                && !Objects.equals(currentPositionId, request.positionId())) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "调整员工岗位请使用「调岗」功能，以保留完整任职记录");
        }
    }

    static void assertDepartmentChangeUsesTransfer(
            Employee employee,
            UUID requestedDepartmentId) {
        if (requestedDepartmentId == null) return;
        UUID currentDepartmentId = employee.getDepartment() == null
                ? null
                : employee.getDepartment().getId();
        if (!requestedDepartmentId.equals(currentDepartmentId)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "调整员工部门请使用「调岗」功能，以保留完整任职记录");
        }
    }

    private static String normalizeResignType(String value) {
        if (isBlank(value)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "离职类型必填");
        }
        return switch (value.trim()) {
            case "VOLUNTARY", "voluntary", "主动", "主动离职" -> "VOLUNTARY";
            case "DISMISSED", "dismissed", "辞退" -> "DISMISSED";
            case "CONTRACT_END", "contract_end", "contractEnd", "合同到期" ->
                    "CONTRACT_END";
            case "RETIRE", "retire", "退休" -> "RETIRE";
            default -> throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "未知离职类型，可选 VOLUNTARY/DISMISSED/CONTRACT_END/RETIRE");
        };
    }

    private static Set<String> requireCompleteOffboardingChecklist(Set<String> codes) {
        if (codes == null || codes.stream().anyMatch(
                code -> code == null || code.isBlank())) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "离职确认清单不能为空");
        }
        Set<String> normalized = Set.copyOf(codes);
        if (!normalized.equals(REQUIRED_OFFBOARDING_CHECKLIST)) {
            Set<String> missing = new java.util.LinkedHashSet<>(REQUIRED_OFFBOARDING_CHECKLIST);
            missing.removeAll(normalized);
            Set<String> unknown = new java.util.LinkedHashSet<>(normalized);
            unknown.removeAll(REQUIRED_OFFBOARDING_CHECKLIST);
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "离职确认清单不完整或包含未知项；缺少=" + missing + "，未知=" + unknown);
        }
        return normalized;
    }

    private static String offboardingHistoryRemark(
            String resignType, String reason, UUID requestId, Set<String> checklistCodes) {
        String checklist = REQUIRED_OFFBOARDING_CHECKLIST.stream()
                .filter(checklistCodes::contains)
                .map(OFFBOARDING_CHECKLIST_LABELS::get)
                .sorted()
                .reduce((left, right) -> left + "；" + right)
                .orElse("");
        return joinTypeAndReason(resignType, reason)
                + "\n离职办理请求：" + requestId
                + "\n人工确认清单（仅记录办理人确认，不代表系统自动核验）："
                + checklist;
    }

    private static String joinTypeAndReason(String type, String reason) {
        if (isBlank(type)) return reason;
        if (isBlank(reason)) return type;
        return type + "：" + reason;
    }

    /** 非空字符串。 */
    private static boolean nn(String s) {
        return s != null && !s.isBlank();
    }

    /** 非空对象（用于日期/枚举等）。 */
    private static boolean nn(Object o) {
        return o != null;
    }
}
