package com.uten.imp.features.org.employee;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.IdCardProblem;
import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.CredentialIssuancePolicy;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentLevelPolicy;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.dto.EmployeeAccountReadiness;
import com.uten.imp.features.org.employee.dto.EmployeeDetail;
import com.uten.imp.features.org.employee.dto.EmployeeOnboardingResult;
import com.uten.imp.features.org.employee.dto.OnboardingRequest;
import com.uten.imp.features.org.position.Position;
import com.uten.imp.features.org.position.PositionRepository;
import com.uten.imp.security.TemporaryPasswordGenerator;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.UUID;

import static com.uten.imp.common.util.Strings.isBlank;

/**
 * 员工入职：单事务原子建号(员工+敏感+薪资+合同+轨迹+联系人+账号)；以及给存量员工补开登录账号。
 *
 * <p>初始密码规则只有一条：档案证件号规范化后够六位就取后六位，派生不出来 (没有证件号或不足六位)
 * 时由系统随机生成，只显示一次。补开账号时证件号有问题 (缺失、身份证号校验不通过、密文解不开) 只提醒、
 * 不阻塞 (V798)；入职录入时身份证号仍严格校验。
 */
@Service
@RequiredArgsConstructor
public class EmployeeOnboardingService {

    private static final Logger log = LoggerFactory.getLogger(EmployeeOnboardingService.class);

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
    private final PasswordEncoder passwordEncoder;
    private final MasterCodeService masterCodeService;
    private final TxSessionVars tx;
    private final EmployeeQueryService queryService;
    private final EmployeeSensitiveWritePolicy sensitiveWritePolicy;
    private final SystemSettingsService settings;
    private final CredentialIssuancePolicy credentialIssuance;
    private final TemporaryPasswordGenerator passwordGenerator;

    // ===== 入职（原子建号） =====
    /** 入职：单事务原子写入员工主档/敏感 PII/薪资/合同/任职轨迹/联系人/证书/学历，并以手机号开号 (初始密码为规范证件号后六位，不足六位时随机生成)。工号服务端分配，profile.code 故意忽略以防缓存客户端重放。 */
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
        // 重放已使用的工号。将序列抬到历史最大后缀；循环只是迁移外数据的防御兜底。
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
            // 录入时严格把关，报出具体哪一位、哪一项不对 (不带号码本身)。
            IdCardProblem problem = IdCardUtil.check(normalizedIdNumber);
            if (problem != null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, problem.message());
            }
            birthDate = IdCardUtil.birthDate(normalizedIdNumber);
            gender = IdCardUtil.gender(normalizedIdNumber);
        }

        String temporaryPassword = initialPassword(p.idType(), normalizedIdNumber);

        Department dept = deptRepo.findById(em.departmentId())
                .filter(department -> !department.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "部门不存在"));
        if (!DepartmentLevelPolicy.canHostEmployees(dept.getLevel())) {
            throw new ApiException(ErrorCode.CONFLICT, "公司和决策层节点不能添加员工");
        }
        Position pos = resolvePosition(em, dept);
        Employee sup = em.supervisorId() == null ? null : empRepo.findById(em.supervisorId())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "直属上级不存在"));

        // 1. 员工主档（户籍/居住地址、邮箱、出生日期、婚姻/政治面貌、办公电话 走 sensitive 加密，见下）
        Employee e = new Employee();
        e.setCode(code);
        e.setFullName(p.fullName());
        e.setGender(gender);
        e.setIdType(p.idType());
        e.setEthnicity(p.ethnicity());
        e.setBirthMonthDay(birthMonthDayOf(birthDate));
        e.setDepartment(dept);
        e.setPosition(pos);
        e.setSupervisor(sup);
        e.setHireDate(em.hireDate());
        e.setStatus(em.status());
        e.setEmploymentType(em.employmentType());
        e.setWorkLocation(em.workLocation());
        e.setSeatNo(em.seatNo());
        e.setAttendanceGroup(em.attendanceGroup());
        e.setPaperArchiveNo(em.paperArchiveNo());
        if ("active".equals(em.status())) {
            // ADR-021：新数据要求——正式入职必须登记转正日期（老数据已按入职日期回填）
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

        // 2. 敏感 PII（加密）——身份证/手机 + V282 扩展字段（地址/邮箱/生日/婚姻/政治/办公电话）
        EmployeeSensitive s = new EmployeeSensitive();
        s.setEmployeeId(e.getId());
        piiWriter.applyIdentity(s, e.getId(), p.idType(), normalizedIdNumber);
        piiWriter.applyPhone(s, p.phone());
        if (birthDate != null) piiWriter.applyBirthDate(s, birthDate);
        if (!isBlank(p.politicalStatus())) piiWriter.applyPoliticalStatus(s, p.politicalStatus());
        if (!isBlank(p.maritalStatus())) piiWriter.applyMaritalStatus(s, p.maritalStatus());
        if (!isBlank(p.hujiAddress())) piiWriter.applyHujiAddress(s, p.hujiAddress());
        if (!isBlank(p.residenceAddress())) piiWriter.applyResidenceAddress(s, p.residenceAddress());
        if (!isBlank(em.officePhone())) piiWriter.applyOfficePhone(s, em.officePhone());
        if (!isBlank(p.email())) piiWriter.applyEmail(s, p.email());
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

        // 新账号初始密码取规范证件号后六位 (不足六位时随机)；不更改已存在账号的密码。
        createAccount(e, loginAccount, temporaryPassword);

        return new EmployeeOnboardingResult(queryService.detail(e.getId()), temporaryPassword, loginAccount);
    }

    // ===== 补开登录账号（批量导入等未自带账号的存量员工） =====
    // 与入职建账号同口径：账号=手机号、初始密码=规范证件号后六位 (派生不出来时随机，限时有效)、
    // Argon2id 入库、首登强制改；权限只来自全员基础包与所在部门配置，入职接口不再接受任何角色/权限参数。
    // 只拦确实开不了的情况 (不存在、已离职、已有账号、没有手机号、手机号被占用、高危开号闸)；
    // 证件号缺失、身份证号校验不通过、证件号密文解不开都不拦 (V798)，返回结果里的 employee.idNumberIssue 带出提醒，
    // 人事任务中心「证件核对」里同步出现待办。
    // 与重置密码同一道闸 (ADR-110)：操作人会看到明文临时密码，按开号后的有效权限 (部门授权、委派) 判定，
    // 目标持有高危权限时只有超级管理员能开通；控制器入口另要求再认证。
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
                        ErrorCode.VALIDATION_FAILED, "该员工缺少手机号，无法开通账号"));

        // 手机号存的是规范化 11 位（ChinaMobileNumber.normalize），直接作登录账号，与用户输入一致。
        String loginAccount = tx.decrypt(s.getPhoneEnc());
        if (isBlank(loginAccount)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "该员工缺少手机号，无法开通账号");
        }
        if (userRepo.existsByLoginAccount(loginAccount)) {
            throw new ApiException(ErrorCode.CONFLICT, "该手机号已被用作其他账号的登录名，请先修改员工手机号");
        }
        // 登录名确认可用之后才解密证件号派生密码：开不了的号不碰证件密文。
        // 证件号密文解不开 (数据损坏、换密钥后没配旧密钥) 也不拦：按派生不出来处理，改用随机临时密码；
        // 解密在保存点里做，不会让本事务作废。返回的员工详情里 idNumberIssue 说明号码读取不出来。
        Optional<String> identity = tx.tryDecrypt(s.getIdCardEnc());
        if (!isBlank(s.getIdCardEnc()) && identity.isEmpty()) {
            log.warn("Account provisioning: the stored identity number could not be decrypted; "
                    + "issued a random temporary password instead");
        }
        String temporaryPassword = initialPassword(e.getIdType(), identity.orElse(null));

        UserAccount account = createAccount(e, loginAccount, temporaryPassword);
        // 在同一事务里按新账号的有效权限判定; 不允许时抛错, 账号随事务回滚, 不留半开的号。
        credentialIssuance.requireCanIssueCredentials(account);

        return new EmployeeOnboardingResult(queryService.detail(e.getId()), temporaryPassword, loginAccount);
    }

    /**
     * 开号就绪检查 (开号确认弹窗打开时先读)：有没有手机号、证件号有没有问题。
     * 只看有没有密文和已存的校验结果，不解密，所以只要 account:support。
     */
    @PreAuthorize("hasAuthority('account:support')")
    @Transactional(readOnly = true)
    public EmployeeAccountReadiness accountReadiness(UUID employeeId) {
        Employee e = empRepo.findById(employeeId)
                .filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "员工不存在"));
        EmployeeSensitive s = sensitiveRepo.findByEmployeeId(e.getId()).orElse(null);
        boolean superAdmin = userRepo.findByEmployeeId(e.getId())
                .map(UserAccount::isSuperAdmin)
                .orElse(false);
        return new EmployeeAccountReadiness(
                s != null && !isBlank(s.getPhoneEnc()),
                EmployeeIdentityCheck.issueOf(
                        s != null && s.getIdCardEnc() != null,
                        s == null ? null : s.getIdCardCheck(),
                        superAdmin));
    }

    /**
     * 能从档案证件号派生出的初始密码：规范化后够六位取后六位 (身份证号校验不通过也一样)，
     * 没有证件号或不足六位时为空。
     */
    static Optional<String> idSuffixPassword(String idType, String idNumber) {
        String normalized = "身份证".equals(idType)
                ? IdCardUtil.normalize(idNumber)
                : idNumber == null ? null : idNumber.strip();
        return normalized == null || normalized.length() < 6
                ? Optional.empty()
                : Optional.of(normalized.substring(normalized.length() - 6));
    }

    /** New accounts only: the ID suffix when derivable, otherwise a one-time random credential. */
    private String initialPassword(String idType, String idNumber) {
        return idSuffixPassword(idType, idNumber).orElseGet(passwordGenerator::generate);
    }

    /** Creates a login account using the same credential rules for onboarding and later provisioning. */
    private UserAccount createAccount(
            Employee employee,
            String loginAccount,
            String temporaryPassword) {
        UserAccount user = new UserAccount();
        user.setEmployeeId(employee.getId());
        user.setLoginAccount(loginAccount);
        user.setPasswordHash(passwordEncoder.encode(temporaryPassword));
        user.setMustChangePassword(true);
        // 与重置密码同口径: 临时密码限时有效 (系统设置「临时密码有效期」), 过期需重新发放。
        user.setTempPasswordExpiresAt(OffsetDateTime.now().plusHours(
                settings.readInt(SystemSettingKey.TEMP_PASSWORD_TTL_HOURS)));
        user.setStatus("active");
        user.setFailedAttempts(0);
        userRepo.save(user);
        return user;
    }

    static void assertHireDateNotFuture(LocalDate hireDate) {
        if (hireDate.isAfter(BusinessTime.today())) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "入职日期不能晚于今天");
        }
    }

    /** 由出生日期派生生日月日 MM-DD（不含年份，非敏感），供生日祝福匹配；birthDate 为 null 返回 null。 */
    static String birthMonthDayOf(LocalDate birthDate) {
        if (birthDate == null) return null;
        return String.format("%02d-%02d", birthDate.getMonthValue(), birthDate.getDayOfMonth());
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


}
