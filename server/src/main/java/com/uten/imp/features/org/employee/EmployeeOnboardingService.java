package com.uten.imp.features.org.employee;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentLevelPolicy;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.dto.EmployeeDetail;
import com.uten.imp.features.org.employee.dto.EmployeeOnboardingResult;
import com.uten.imp.features.org.employee.dto.OnboardingRequest;
import com.uten.imp.features.org.position.Position;
import com.uten.imp.features.org.position.PositionRepository;
import com.uten.imp.features.rbac.Role;
import com.uten.imp.features.rbac.RoleRepository;
import com.uten.imp.features.rbac.UserRole;
import com.uten.imp.features.rbac.UserRoleId;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.security.AdminGrantGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static com.uten.imp.common.util.Strings.isBlank;

/** 员工入职：单事务原子建号（员工+敏感+薪资+合同+轨迹+联系人+账号+角色）。 */
@Service
@RequiredArgsConstructor
public class EmployeeOnboardingService {

    private final EmployeeRepository empRepo;
    private final EmployeeSensitiveRepository sensitiveRepo;
    private final EmployeePiiWriter piiWriter;
    private final EmployeeCompensationRepository compensationRepo;
    private final EmergencyContactRepository emergencyRepo;
    private final EmployeeCredentialRepository credentialRepo;
    private final EmployeeEducationRepository educationRepo;
    private final EmployeeContractRepository contractRepo;
    private final EmploymentHistoryRepository historyRepo;
    private final DepartmentRepository deptRepo;
    private final PositionRepository positionRepo;
    private final EntityManager entityManager;
    private final UserAccountRepository userRepo;
    private final RoleRepository roleRepo;
    private final UserRoleRepository userRoleRepo;
    private final PasswordEncoder passwordEncoder;
    private final MasterCodeService masterCodeService;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final EmployeeQueryService queryService;
    private final EmployeeSensitiveWritePolicy sensitiveWritePolicy;

    // ===== 入职（原子建号） =====
    @PreAuthorize("hasAuthority('employee:create')")
    @Transactional
    public EmployeeOnboardingResult onboard(OnboardingRequest req) {
        sensitiveWritePolicy.assertOnboardingAllowed(req);
        tx.bind();
        OnboardingRequest.Profile p = req.profile();
        OnboardingRequest.Employment em = req.employment();
        if (p == null || em == null || isBlank(p.fullName())
                || isBlank(p.idType()) || isBlank(p.idNumber()) || isBlank(p.phone())
                || em.departmentId() == null || em.hireDate() == null
                || isBlank(em.employmentType()) || isBlank(em.status())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "必填项缺失");
        }
        assertHireDateNotFuture(em.hireDate());
        // 入职工号完全由服务端分配。profile.code 仅为旧客户端兼容字段，故意忽略，避免缓存客户端
        // 重放已使用的工号。V206 将序列抬到历史最大后缀；循环只是迁移外数据的防御兜底。
        String code = masterCodeService.nextCode(MasterCodePrefix.EMPLOYEE);
        while (empRepo.existsByCode(code)) {
            code = masterCodeService.nextCode(MasterCodePrefix.EMPLOYEE);
        }
        // 登录账号默认 = 手机号（不再用工号）。
        String loginAccount = isBlank(req.account() != null ? req.account().loginAccount() : null)
                ? p.phone().trim() : req.account().loginAccount();
        if (userRepo.existsByLoginAccount(loginAccount)) {
            throw new ApiException(ErrorCode.CONFLICT, "登录账号已存在");
        }
        // 身份证校验 + 派生
        LocalDate birthDate = p.birthDate();
        String gender = p.gender();
        String normalizedIdNumber = p.idNumber().trim();
        if ("身份证".equals(p.idType())) {
            normalizedIdNumber = IdCardUtil.normalize(p.idNumber());
            if (!IdCardUtil.isValid(normalizedIdNumber)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "身份证号校验未通过");
            }
            birthDate = IdCardUtil.birthDate(normalizedIdNumber);
            gender = IdCardUtil.gender(normalizedIdNumber);
        }

        Department dept = deptRepo.findById(em.departmentId())
                .filter(department -> !department.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "部门不存在"));
        if (!DepartmentLevelPolicy.canHostEmployees(dept.getLevel())) {
            throw new ApiException(ErrorCode.CONFLICT, "公司和决策层节点不能添加员工");
        }
        Position pos = resolvePosition(em, dept);
        Employee sup = em.supervisorId() == null ? null : empRepo.findById(em.supervisorId())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "直属上级不存在"));

        // 1. 员工主档
        Employee e = new Employee();
        e.setCode(code);
        e.setFullName(p.fullName());
        e.setGender(gender);
        e.setIdType(p.idType());
        e.setBirthDate(birthDate);
        e.setEthnicity(p.ethnicity());
        e.setPoliticalStatus(p.politicalStatus());
        e.setMaritalStatus(p.maritalStatus());
        e.setHujiAddress(p.hujiAddress());
        e.setResidenceAddress(p.residenceAddress());
        e.setDepartment(dept);
        e.setPosition(pos);
        e.setSupervisor(sup);
        e.setHireDate(em.hireDate());
        e.setStatus(em.status());
        e.setEmploymentType(em.employmentType());
        e.setWorkLocation(em.workLocation());
        e.setSeatNo(em.seatNo());
        e.setAttendanceGroup(em.attendanceGroup());
        e.setOfficePhone(em.officePhone());
        e.setEmail(p.email());
        e.setPaperArchiveNo(em.paperArchiveNo());
        if ("active".equals(em.status())) {
            // ADR-021：新数据要求——正式入职必须登记转正日期（老数据已由 V210 按入职日期回填）
            if (em.confirmedAt() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "正式入职的员工必须填写转正日期；试用期员工请选择「试用」状态");
            }
            if (em.confirmedAt().isAfter(BusinessTime.today())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "转正日期不能晚于今天");
            }
            if (em.confirmedAt().isBefore(em.hireDate())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "转正日期不能早于入职日期");
            }
            e.setConfirmedAt(em.confirmedAt());
        }
        empRepo.save(e);

        // 2. 敏感 PII（加密）
        EmployeeSensitive s = new EmployeeSensitive();
        s.setEmployeeId(e.getId());
        piiWriter.applyIdentity(s, e.getId(), p.idType(), normalizedIdNumber);
        piiWriter.applyPhone(s, p.phone());
        OnboardingRequest.Compensation comp = req.compensation();
        if (comp != null) {
            if (!isBlank(comp.bankAccount())) s.setBankAccountEnc(tx.encrypt(comp.bankAccount()));
            if (!isBlank(comp.bankBranch())) s.setBankBranchEnc(tx.encrypt(comp.bankBranch()));
        }
        sensitiveRepo.save(s);

        // 3. 薪资（如提供）
        if (EmployeeSensitiveWritePolicy.hasCompensationWrite(comp)) {
            EmployeeCompensation c = new EmployeeCompensation();
            c.setEmployeeId(e.getId());
            if (!isBlank(comp.baseSalary())) c.setBaseSalaryEnc(tx.encrypt(comp.baseSalary()));
            if (!isBlank(comp.perfSalary())) c.setPerfSalaryEnc(tx.encrypt(comp.perfSalary()));
            if (!isBlank(comp.socialInsuranceBase())) c.setSocialInsuranceBaseEnc(tx.encrypt(comp.socialInsuranceBase()));
            if (!isBlank(comp.housingFundBase())) c.setHousingFundBaseEnc(tx.encrypt(comp.housingFundBase()));
            if (!isBlank(comp.allowanceStandard())) c.setAllowanceStandardEnc(tx.encrypt(comp.allowanceStandard()));
            c.setSocialInsuranceLocation(comp.socialInsuranceLocation());
            compensationRepo.save(c);
        }

        // 4. 合同（sign_order=1）
        OnboardingRequest.Contract ct = req.contract();
        if (ct != null) {
            EmployeeContract contract = new EmployeeContract();
            contract.setEmployee(e);
            contract.setContractType(ct.contractType() == null ? "fixed" : ct.contractType());
            contract.setStartDate(ct.startDate() == null ? em.hireDate() : ct.startDate());
            contract.setEndDate(ct.endDate());
            contract.setProbationMonths(ct.probationMonths());
            contract.setSignOrder(1);
            contractRepo.save(contract);
        }

        // 5. 任职轨迹：入职
        EmploymentHistory h = new EmploymentHistory();
        h.setEmployee(e);
        h.setEventType("onboard");
        h.setToDepartmentId(dept.getId());
        h.setToPositionId(pos == null ? null : pos.getId());
        h.setEventDate(em.hireDate());
        historyRepo.save(h);

        // 6. 紧急联系人
        if (req.emergencyContacts() != null) {
            int order = 0;
            for (OnboardingRequest.EmergencyContactInput ec : req.emergencyContacts()) {
                EmergencyContact contact = new EmergencyContact();
                contact.setEmployee(e);
                contact.setName(ec.name());
                contact.setPhoneEnc(isBlank(ec.phone()) ? null : tx.encrypt(ec.phone()));
                contact.setRelationship(ec.relationship());
                contact.setSortOrder(ec.sortOrder() == null ? order : ec.sortOrder());
                emergencyRepo.save(contact);
                order++;
            }
        }

        // 6b. 证书 / 学历（可选，随入职原子写入）
        if (req.certificates() != null) {
            for (OnboardingRequest.CredentialInput ci : req.certificates()) {
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
        if (req.educations() != null) {
            for (OnboardingRequest.EducationInput ei : req.educations()) {
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

        String temporaryPassword = lastSix(normalizedIdNumber);
        if (temporaryPassword.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "身份证号不足 6 位，无法生成初始密码");
        }
        List<String> roleCodes = (req.account() == null || req.account().roles() == null || req.account().roles().isEmpty())
                ? List.of("employee") : req.account().roles();
        createAccount(e, loginAccount, temporaryPassword, roleCodes);

        return new EmployeeOnboardingResult(queryService.detail(e.getId()), temporaryPassword, loginAccount);
    }

    // ===== 补开登录账号（批量导入等未自带账号的存量员工） =====
    // 与入职建账号同口径：账号=手机号、初始密码=证件号后6位、Argon2id 入库、首登强制改、授 employee 角色。
    @PreAuthorize("hasAuthority('account:support')")
    @Transactional
    public EmployeeOnboardingResult provisionAccount(UUID employeeId) {
        tx.bind();

        Employee e = empRepo.findById(employeeId)
                .filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "员工不存在"));
        if ("resigned".equals(e.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT, "离职员工必须先完成复职流程，不能开通登录账号");
        }
        if (userRepo.findByEmployeeId(employeeId).isPresent()) {
            throw new ApiException(ErrorCode.CONFLICT, "该员工已开通登录账号");
        }
        EmployeeSensitive s = sensitiveRepo.findByEmployeeId(employeeId)
                .orElseThrow(() -> new ApiException(
                        ErrorCode.VALIDATION_FAILED, "缺少手机号或身份证，无法开通账号"));

        // 手机号存的是规范化 11 位（ChinaMobileNumber.normalize），直接作登录账号，与用户输入一致。
        String loginAccount = tx.decrypt(s.getPhoneEnc());
        if (isBlank(loginAccount)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "该员工缺少手机号，无法开通账号");
        }
        String temporaryPassword = lastSix(tx.decrypt(s.getIdCardEnc()));
        if (isBlank(temporaryPassword)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "该员工身份证号缺失或不足 6 位，无法生成初始密码");
        }
        if (userRepo.existsByLoginAccount(loginAccount)) {
            throw new ApiException(ErrorCode.CONFLICT, "该手机号已被用作其他账号的登录名，请先修改员工手机号");
        }

        List<String> roleCodes = List.of("employee");
        createAccount(e, loginAccount, temporaryPassword, roleCodes);

        return new EmployeeOnboardingResult(queryService.detail(e.getId()), temporaryPassword, loginAccount);
    }

    /** Creates a login account using the same credential and role rules for onboarding and later provisioning. */
    private void createAccount(
            Employee employee,
            String loginAccount,
            String temporaryPassword,
            List<String> roleCodes) {
        if (roleCodes == null || roleCodes.isEmpty()
                || roleCodes.stream().anyMatch(code -> isBlank(code))) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "账号角色不能为空");
        }
        List<String> uniqueRoleCodes = roleCodes.stream().distinct().toList();
        AdminGrantGuard.checkAdminGrant(currentUser, uniqueRoleCodes);
        List<Role> roles = roleRepo.findByCodeIn(uniqueRoleCodes);
        Set<String> resolvedCodes = roles.stream().map(Role::getCode).collect(Collectors.toSet());
        List<String> missingCodes = uniqueRoleCodes.stream()
                .filter(code -> !resolvedCodes.contains(code))
                .toList();
        if (!missingCodes.isEmpty()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "账号角色不存在: " + String.join(", ", missingCodes));
        }

        UserAccount user = new UserAccount();
        user.setEmployeeId(employee.getId());
        user.setLoginAccount(loginAccount);
        user.setPasswordHash(passwordEncoder.encode(temporaryPassword));
        user.setMustChangePassword(true);
        user.setStatus("active");
        user.setFailedAttempts(0);
        userRepo.save(user);

        for (Role role : roles) {
            UserRole ur = new UserRole();
            ur.setId(new UserRoleId(user.getId(), role.getId()));
            userRoleRepo.save(ur);
        }
    }

    static void assertHireDateNotFuture(LocalDate hireDate) {
        if (hireDate.isAfter(BusinessTime.today())) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "入职日期不能晚于今天");
        }
    }

    /**
     * 解析入职岗位：{@code positionId} 优先；否则按 {@code positionName} 在本部门查（忽略大小写，
     * 命中复用，未命中则新建：code 由序列生成、level=「员工」、sortOrder=0）；两者都空返回 null。
     * 新建在本入职事务内完成；同部门规范化名称使用事务级咨询锁，避免并发生成重复岗位。
     */
    private Position resolvePosition(OnboardingRequest.Employment em, Department dept) {
        if (em.positionId() != null) {
            return positionRepo
                    .findByIdAndDepartmentIdAndDeletedFalse(em.positionId(), dept.getId())
                    .orElseThrow(() -> new ApiException(
                            ErrorCode.CONFLICT,
                            "岗位不存在、已停用或不属于所选部门"));
        }
        if (isBlank(em.positionName())) {
            return null;
        }
        String name = em.positionName().trim();
        String normalizedName = normalizePositionName(name);
        acquirePositionNameLock(dept.getId(), normalizedName);
        Position existing = positionRepo
                .findFirstActiveByNormalizedName(dept.getId(), normalizedName)
                .orElse(null);
        if (existing != null) {
            return existing;
        }

        Position created = new Position();
        created.setCode(masterCodeService.nextCode(MasterCodePrefix.POSITION));
        created.setName(name);
        created.setLevel("员工");
        created.setSortOrder(0);
        created.setDepartment(dept);
        return positionRepo.save(created);
    }

    static String normalizePositionName(String name) {
        return name.trim().toLowerCase(Locale.ROOT);
    }

    private void acquirePositionNameLock(UUID departmentId, String normalizedName) {
        entityManager.createNativeQuery("""
                        SELECT pg_advisory_xact_lock(
                            hashtextextended(
                                'POSITION_NAME|' || CAST(:departmentId AS text)
                                || '|' || CAST(:normalizedName AS text),
                                0))
                        """)
                .setParameter("departmentId", departmentId)
                .setParameter("normalizedName", normalizedName)
                .getSingleResult();
    }

    /** 身份证号后 6 位作为一次性临时密码；不足 6 位时拒绝开通账号。 */
    static String lastSix(String idNumber) {
        if (idNumber == null) {
            return "";
        }
        String trimmed = idNumber.trim();
        return trimmed.length() < 6 ? "" : trimmed.substring(trimmed.length() - 6);
    }

}
