package com.uten.imp.features.org.employee;

import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.dto.EmployeeDetail;
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
import lombok.RequiredArgsConstructor;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.List;

import static com.uten.imp.common.util.Strings.isBlank;

/** 员工入职：单事务原子建号（员工+敏感+薪资+合同+轨迹+联系人+账号+角色）。 */
@Service
@RequiredArgsConstructor
public class EmployeeOnboardingService {

    private final EmployeeRepository empRepo;
    private final EmployeeSensitiveRepository sensitiveRepo;
    private final EmployeeCompensationRepository compensationRepo;
    private final EmergencyContactRepository emergencyRepo;
    private final EmployeeCredentialRepository credentialRepo;
    private final EmployeeEducationRepository educationRepo;
    private final EmployeeContractRepository contractRepo;
    private final EmploymentHistoryRepository historyRepo;
    private final DepartmentRepository deptRepo;
    private final PositionRepository positionRepo;
    private final UserAccountRepository userRepo;
    private final RoleRepository roleRepo;
    private final UserRoleRepository userRoleRepo;
    private final PasswordEncoder passwordEncoder;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final EmployeeQueryService queryService;

    // ===== 入职（原子建号） =====
    @Transactional
    public EmployeeDetail onboard(OnboardingRequest req) {
        tx.bind();
        OnboardingRequest.Profile p = req.profile();
        OnboardingRequest.Employment em = req.employment();
        if (p == null || em == null || isBlank(p.code()) || isBlank(p.fullName())
                || isBlank(p.idType()) || isBlank(p.idNumber()) || isBlank(p.phone())
                || em.departmentId() == null || em.hireDate() == null
                || isBlank(em.employmentType()) || isBlank(em.status())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "必填项缺失");
        }
        if (empRepo.existsByCode(p.code())) {
            throw new ApiException(ErrorCode.CONFLICT, "工号已存在");
        }
        String loginAccount = isBlank(req.account() != null ? req.account().loginAccount() : null)
                ? p.code() : req.account().loginAccount();
        if (userRepo.existsByLoginAccount(loginAccount)) {
            throw new ApiException(ErrorCode.CONFLICT, "登录账号已存在");
        }
        // 身份证校验 + 派生
        LocalDate birthDate = p.birthDate();
        String gender = p.gender();
        if ("身份证".equals(p.idType())) {
            if (!IdCardUtil.isValid(p.idNumber())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "身份证号校验未通过");
            }
            birthDate = IdCardUtil.birthDate(p.idNumber());
            gender = IdCardUtil.gender(p.idNumber());
        }

        Department dept = deptRepo.findById(em.departmentId())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "部门不存在"));
        Position pos = em.positionId() == null ? null : positionRepo.findById(em.positionId())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "岗位不存在"));
        Employee sup = em.supervisorId() == null ? null : empRepo.findById(em.supervisorId())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "直属上级不存在"));

        // 1. 员工主档
        Employee e = new Employee();
        e.setCode(p.code());
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
            e.setConfirmedAt(LocalDate.now());
        }
        empRepo.save(e);

        // 2. 敏感 PII（加密）
        EmployeeSensitive s = new EmployeeSensitive();
        s.setEmployeeId(e.getId());
        s.setIdCardEnc(tx.encrypt(p.idNumber()));
        s.setIdCardLast4(IdCardUtil.last4(p.idNumber()));
        // 身份证号查重（HMAC，M3）
        String idHash = tx.hmac(p.idNumber());
        if (idHash != null && sensitiveRepo.existsByIdCardHash(idHash)) {
            throw new ApiException(ErrorCode.CONFLICT, "该身份证号已存在");
        }
        s.setIdCardHash(idHash);
        s.setPhoneEnc(tx.encrypt(p.phone()));
        s.setPhoneHash(tx.hmac(p.phone()));
        OnboardingRequest.Compensation comp = req.compensation();
        if (comp != null) {
            if (!isBlank(comp.bankAccount())) s.setBankAccountEnc(tx.encrypt(comp.bankAccount()));
            if (!isBlank(comp.bankBranch())) s.setBankBranchEnc(tx.encrypt(comp.bankBranch()));
        }
        sensitiveRepo.save(s);

        // 3. 薪资（如提供）
        if (comp != null && hasAnySalary(comp)) {
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

        // 7. 账号（密码 = 身份证后六位，Argon2id；首登强制改）
        UserAccount user = new UserAccount();
        user.setEmployeeId(e.getId());
        user.setLoginAccount(loginAccount);
        user.setPasswordHash(passwordEncoder.encode(IdCardUtil.last6(p.idNumber())));
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

        return queryService.detail(e.getId());
    }

    private static boolean hasAnySalary(OnboardingRequest.Compensation c) {
        return !isBlank(c.baseSalary()) || !isBlank(c.perfSalary()) || !isBlank(c.socialInsuranceBase())
                || !isBlank(c.housingFundBase()) || !isBlank(c.allowanceStandard());
    }
}
