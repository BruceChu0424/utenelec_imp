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
import java.util.UUID;

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
            e.setConfirmedAt(BusinessTime.today());
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

        // 7. 账号（一次性临时密码=证件号后6位，仅在本次响应交付；Argon2id 入库；首登强制改）
        String temporaryPassword = lastSix(normalizedIdNumber);
        UserAccount user = new UserAccount();
        user.setEmployeeId(e.getId());
        user.setLoginAccount(loginAccount);
        user.setPasswordHash(passwordEncoder.encode(temporaryPassword));
        user.setMustChangePassword(true);
        user.setStatus("active");
        user.setFailedAttempts(0);
        userRepo.save(user);

        // 8. 角色（默认 employee）—— 仅 admin / super admin 可授予 admin 角色（防 HR 提权，C1）
        List<String> roleCodes = (req.account() == null || req.account().roles() == null || req.account().roles().isEmpty())
                ? List.of("employee") : req.account().roles();
        AdminGrantGuard.checkAdminGrant(currentUser, roleCodes);
        for (Role role : roleRepo.findByCodeIn(roleCodes)) {
            UserRole ur = new UserRole();
            ur.setId(new UserRoleId(user.getId(), role.getId()));
            userRoleRepo.save(ur);
        }

        return new EmployeeOnboardingResult(queryService.detail(e.getId()), temporaryPassword, loginAccount);
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

    /** 证件号后 6 位作为一次性临时密码（不足 6 位取全部）。 */
    static String lastSix(String idNumber) {
        if (idNumber == null) {
            return "";
        }
        String trimmed = idNumber.trim();
        return trimmed.length() <= 6 ? trimmed : trimmed.substring(trimmed.length() - 6);
    }

}
