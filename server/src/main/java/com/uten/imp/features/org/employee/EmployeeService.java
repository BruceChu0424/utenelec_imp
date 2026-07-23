package com.uten.imp.features.org.employee;

import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.dto.*;
import com.uten.imp.features.org.position.Position;
import com.uten.imp.features.org.position.PositionRepository;
import com.uten.imp.features.rbac.*;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DataAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.*;

/**
 * 员工档案服务。核心：入职单事务原子建号（employee+敏感+薪资+合同+轨迹+账号）；
 * 列表/详情按角色脱敏；调岗/离职/转正写任职轨迹。
 */
@Service
@RequiredArgsConstructor
public class EmployeeService {

    private final EmployeeRepository empRepo;
    private final EmployeeSensitiveRepository sensitiveRepo;
    private final EmployeeCompensationRepository compensationRepo;
    private final EmergencyContactRepository emergencyRepo;
    private final EmployeeContractRepository contractRepo;
    private final EmploymentHistoryRepository historyRepo;
    private final DepartmentRepository deptRepo;
    private final PositionRepository positionRepo;
    private final UserAccountRepository userRepo;
    private final RoleRepository roleRepo;
    private final UserRoleRepository userRoleRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final PasswordEncoder passwordEncoder;
    private final TxSessionVars tx;
    private final DataAccessPolicy policy;
    private final SecurityContextCurrentUser currentUser;

    // ===== 列表（摘要，无敏感） =====
    @Transactional(readOnly = true)
    public PageResponse<EmployeeListItem> list(int page, int size, String search,
                                                Set<String> statuses, UUID departmentId, boolean includeSubtree) {
        Collection<UUID> deptIds = resolveDeptIds(departmentId, includeSubtree);
        Specification<Employee> spec = (root, q, cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (search != null && !search.isBlank()) {
                String like = "%" + search.toLowerCase() + "%";
                ps.add(cb.or(
                        cb.like(cb.lower(root.get("code")), like),
                        cb.like(cb.lower(root.get("fullName")), like)));
            }
            if (statuses != null && !statuses.isEmpty()) {
                ps.add(root.get("status").in(statuses));
            }
            if (deptIds != null && !deptIds.isEmpty()) {
                ps.add(root.get("department").get("id").in(deptIds));
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        PageRequest pageable = PageRequest.of(Math.max(0, page - 1), Math.min(Math.max(1, size), 100),
                Sort.by(Sort.Direction.ASC, "code"));
        Page<Employee> p = empRepo.findAll(spec, pageable);
        List<EmployeeListItem> items = p.getContent().stream().map(this::toList).toList();
        return new PageResponse<>(items, page, size, p.getTotalElements(), p.getTotalPages());
    }

    // ===== 详情（按角色脱敏） =====
    @Transactional(readOnly = true)
    public EmployeeDetail detail(UUID id) {
        tx.bind();
        Employee e = requireEmployee(id);
        Set<String> roles = currentUser.get().map(AuthUser::getRoles).orElse(Set.of());
        EmployeeSensitive s = sensitiveRepo.findByEmployeeId(id).orElse(null);
        EmployeeCompensation c = compensationRepo.findByEmployeeId(id).orElse(null);

        EmployeeDetail d = new EmployeeDetail();
        d.setId(e.getId());
        d.setCode(e.getCode());
        d.setFullName(e.getFullName());
        d.setGender(e.getGender());
        d.setIdType(e.getIdType());
        d.setBirthDate(e.getBirthDate());
        d.setEthnicity(e.getEthnicity());
        d.setPoliticalStatus(e.getPoliticalStatus());
        d.setMaritalStatus(e.getMaritalStatus());
        d.setHujiAddress(e.getHujiAddress());
        d.setResidenceAddress(e.getResidenceAddress());
        d.setDepartmentId(e.getDepartment() == null ? null : e.getDepartment().getId());
        d.setDepartmentName(e.getDepartment() == null ? null : e.getDepartment().getName());
        d.setPositionId(e.getPosition() == null ? null : e.getPosition().getId());
        d.setPositionName(e.getPosition() == null ? null : e.getPosition().getName());
        d.setSupervisorId(e.getSupervisor() == null ? null : e.getSupervisor().getId());
        d.setSupervisorName(e.getSupervisor() == null ? null : e.getSupervisor().getFullName());
        d.setHireDate(e.getHireDate());
        d.setConfirmedAt(e.getConfirmedAt());
        d.setStatus(e.getStatus());
        d.setEmploymentType(e.getEmploymentType());
        d.setWorkLocation(e.getWorkLocation());
        d.setSeatNo(e.getSeatNo());
        d.setAttendanceGroup(e.getAttendanceGroup());
        d.setOfficePhone(e.getOfficePhone());
        d.setEmail(e.getEmail());
        d.setPaperArchiveNo(e.getPaperArchiveNo());

        // 合同（当前合同 + 续签次数 + 试用期结束日）
        List<EmployeeContract> contracts = contractRepo.findByEmployeeIdOrderBySignOrderAsc(id);
        if (!contracts.isEmpty()) {
            EmployeeContract current = contracts.get(contracts.size() - 1);
            d.setContractType(current.getContractType());
            d.setContractStart(current.getStartDate());
            d.setContractEnd(current.getEndDate());
            d.setProbationMonths(current.getProbationMonths());
            d.setProbationEndDate(probationEnd(e.getHireDate(), current.getProbationMonths()));
        }
        d.setRenewCount((int) contractRepo.countByEmployeeId(id));

        fillSensitive(d, s, c, roles);

        // 紧急联系人（phone 按角色脱敏）
        List<NestedDtos.EmergencyContactDto> ec = emergencyRepo.findByEmployeeIdOrderBySortOrderAsc(id).stream()
                .map(x -> new NestedDtos.EmergencyContactDto(x.getId(), x.getName(),
                        decryptMasked(x.getPhoneEnc(), roles), x.getRelationship()))
                .toList();
        d.setEmergencyContacts(ec);

        // 任职轨迹
        List<NestedDtos.EmploymentHistoryDto> hist = historyRepo.findByEmployeeIdOrderByEventDateDesc(id).stream()
                .map(this::toHistory).toList();
        d.setHistory(hist);

        // 隐私保护（M5/PIPL）：非 hr/admin 不可见民族/政治面貌/婚姻/户籍/现居/出生日期
        if (!policy.canSeeIdCardAndBank(roles)) {
            d.setEthnicity(null);
            d.setPoliticalStatus(null);
            d.setMaritalStatus(null);
            d.setHujiAddress(null);
            d.setResidenceAddress(null);
            d.setBirthDate(null);
        }

        return d;
    }

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

        // 7. 账号（密码 = 身份证后六位，Argon2id；首登强制改）
        UserAccount user = new UserAccount();
        user.setEmployeeId(e.getId());
        user.setLoginAccount(loginAccount);
        user.setPasswordHash(passwordEncoder.encode(IdCardUtil.last6(p.idNumber())));
        user.setMustChangePassword(true);
        user.setStatus("active");
        user.setFailedAttempts(0);
        userRepo.save(user);

        // 8. 角色（默认 employee）—— 仅 admin 可授予 admin 角色（防 HR 提权，C1）
        List<String> roleCodes = (req.account() == null || req.account().roles() == null || req.account().roles().isEmpty())
                ? List.of("employee") : req.account().roles();
        if (roleCodes.contains("admin")
                && !currentUser.get().map(u -> u.getRoles().contains("admin")).orElse(false)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "仅管理员可授予 admin 角色");
        }
        for (Role role : roleRepo.findByCodeIn(roleCodes)) {
            UserRole ur = new UserRole();
            ur.setId(new UserRoleId(user.getId(), role.getId()));
            userRoleRepo.save(ur);
        }

        return detail(e.getId());
    }

    // ===== 更新 =====
    @Transactional
    public EmployeeDetail update(UUID id, UpdateEmployeeRequest r) {
        tx.bind();
        Employee e = requireEmployee(id);
        if (nn(r.fullName())) e.setFullName(r.fullName());
        if (nn(r.gender())) e.setGender(r.gender());
        if (nn(r.birthDate())) e.setBirthDate(r.birthDate());
        if (nn(r.ethnicity())) e.setEthnicity(r.ethnicity());
        if (nn(r.politicalStatus())) e.setPoliticalStatus(r.politicalStatus());
        if (nn(r.maritalStatus())) e.setMaritalStatus(r.maritalStatus());
        if (nn(r.hujiAddress())) e.setHujiAddress(r.hujiAddress());
        if (nn(r.residenceAddress())) e.setResidenceAddress(r.residenceAddress());
        if (r.departmentId() != null) e.setDepartment(deptRepo.findById(r.departmentId())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "部门不存在")));
        if (r.positionId() != null) e.setPosition(positionRepo.findById(r.positionId())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "岗位不存在")));
        if (r.supervisorId() != null) e.setSupervisor(empRepo.findById(r.supervisorId())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "直属上级不存在")));
        if (nn(r.workLocation())) e.setWorkLocation(r.workLocation());
        if (nn(r.seatNo())) e.setSeatNo(r.seatNo());
        if (nn(r.attendanceGroup())) e.setAttendanceGroup(r.attendanceGroup());
        if (nn(r.officePhone())) e.setOfficePhone(r.officePhone());
        if (nn(r.email())) e.setEmail(r.email());
        if (nn(r.paperArchiveNo())) e.setPaperArchiveNo(r.paperArchiveNo());
        if (nn(r.status())) e.setStatus(r.status());
        if (nn(r.employmentType())) e.setEmploymentType(r.employmentType());
        if (r.confirmedAt() != null) e.setConfirmedAt(r.confirmedAt());
        empRepo.save(e);

        updateSensitive(id, r);
        updateCompensation(id, r);
        return detail(id);
    }

    private void updateSensitive(UUID id, UpdateEmployeeRequest r) {
        if (isBlank(r.idNumber()) && isBlank(r.phone()) && isBlank(r.bankAccount()) && isBlank(r.bankBranch())) {
            return;
        }
        EmployeeSensitive s = sensitiveRepo.findByEmployeeId(id).orElseGet(() -> {
            EmployeeSensitive ns = new EmployeeSensitive();
            ns.setEmployeeId(id);
            return ns;
        });
        if (!isBlank(r.idNumber())) {
            s.setIdCardEnc(tx.encrypt(r.idNumber()));
            s.setIdCardLast4(IdCardUtil.last4(r.idNumber()));
            String idHash = tx.hmac(r.idNumber());
            if (idHash != null && sensitiveRepo.existsByIdCardHashAndEmployeeIdNot(idHash, id)) {
                throw new ApiException(ErrorCode.CONFLICT, "该身份证号已被其他员工使用");
            }
            s.setIdCardHash(idHash);
        }
        if (!isBlank(r.phone())) s.setPhoneEnc(tx.encrypt(r.phone()));
        if (!isBlank(r.bankAccount())) s.setBankAccountEnc(tx.encrypt(r.bankAccount()));
        if (!isBlank(r.bankBranch())) s.setBankBranchEnc(tx.encrypt(r.bankBranch()));
        sensitiveRepo.save(s);
    }

    private void updateCompensation(UUID id, UpdateEmployeeRequest r) {
        if (isBlank(r.baseSalary()) && isBlank(r.perfSalary()) && isBlank(r.socialInsuranceBase())
                && isBlank(r.housingFundBase()) && isBlank(r.allowanceStandard()) && isBlank(r.socialInsuranceLocation())) {
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
    @Transactional
    public void transfer(UUID id, TransferRequest req) {
        tx.bind();
        Employee e = requireEmployee(id);
        if ("resigned".equals(e.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT, "该员工已离职，不可调岗");
        }
        Department to = deptRepo.findById(req.toDepartmentId())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "目标部门不存在"));
        Position toPos = req.toPositionId() == null ? null : positionRepo.findById(req.toPositionId()).orElse(null);

        EmploymentHistory h = new EmploymentHistory();
        h.setEmployee(e);
        h.setEventType("transfer");
        h.setFromDepartmentId(e.getDepartment() == null ? null : e.getDepartment().getId());
        h.setToDepartmentId(to.getId());
        h.setFromPositionId(e.getPosition() == null ? null : e.getPosition().getId());
        h.setToPositionId(toPos == null ? null : toPos.getId());
        h.setEventDate(req.effectiveDate());
        h.setRemark(req.remark());
        historyRepo.save(h);

        e.setDepartment(to);
        e.setPosition(toPos);
        if (req.supervisorId() != null) {
            e.setSupervisor(empRepo.findById(req.supervisorId()).orElse(null));
        }
        empRepo.save(e);
    }

    @Transactional
    public void offboard(UUID id, OffboardRequest req) {
        tx.bind();
        Employee e = requireEmployee(id);
        if ("resigned".equals(e.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT, "该员工已离职");
        }
        EmploymentHistory h = new EmploymentHistory();
        h.setEmployee(e);
        h.setEventType("resign");
        h.setFromDepartmentId(e.getDepartment() == null ? null : e.getDepartment().getId());
        h.setEventDate(req.effectiveDate());
        h.setRemark(joinTypeAndReason(req.resignType(), req.reason()));
        historyRepo.save(h);

        e.setStatus("resigned");
        empRepo.save(e);

        // 停用账号并撤销令牌
        userRepo.findByEmployeeId(id).ifPresent(u -> {
            u.setStatus("disabled");
            userRepo.save(u);
            refreshTokenRepo.revokeAllByUserId(u.getId());
        });
    }

    @Transactional
    public void confirm(UUID id) {
        tx.bind();
        Employee e = requireEmployee(id);
        if (!"probation".equals(e.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT, "仅试用期员工可转正");
        }
        e.setStatus("active");
        e.setConfirmedAt(LocalDate.now());
        empRepo.save(e);
    }

    @Transactional(readOnly = true)
    public List<NestedDtos.EmploymentHistoryDto> history(UUID id) {
        requireEmployee(id);
        return historyRepo.findByEmployeeIdOrderByEventDateDesc(id).stream().map(this::toHistory).toList();
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Employee e = requireEmployee(id);
        e.setDeleted(true);
        e.setDeletedAt(OffsetDateTime.now());
        empRepo.save(e);
        // 连带停用登录账号并撤销令牌（H2）
        userRepo.findByEmployeeId(id).ifPresent(u -> {
            u.setStatus("disabled");
            userRepo.save(u);
            refreshTokenRepo.revokeAllByUserId(u.getId());
        });
    }

    // ===== 辅助 =====

    private void fillSensitive(EmployeeDetail d, EmployeeSensitive s, EmployeeCompensation c, Set<String> roles) {
        if (s != null) {
            String idPlain = tx.decrypt(s.getIdCardEnc());
            String phonePlain = tx.decrypt(s.getPhoneEnc());
            if (policy.canSeeIdCardAndBank(roles)) {
                d.setIdNumber(idPlain);
                d.setPhone(phonePlain);
                if (s.getBankAccountEnc() != null) d.setBankAccount(tx.decrypt(s.getBankAccountEnc()));
                if (s.getBankBranchEnc() != null) d.setBankBranch(tx.decrypt(s.getBankBranchEnc()));
            } else {
                d.setIdNumber(IdCardUtil.mask(idPlain));
                d.setPhone(maskPhone(phonePlain));
            }
        }
        if (c != null) {
            if (policy.canSeeSalary(roles)) {
                d.setBaseSalary(tx.decrypt(c.getBaseSalaryEnc()));
                d.setPerfSalary(tx.decrypt(c.getPerfSalaryEnc()));
                d.setSocialInsuranceBase(tx.decrypt(c.getSocialInsuranceBaseEnc()));
                d.setHousingFundBase(tx.decrypt(c.getHousingFundBaseEnc()));
                d.setAllowanceStandard(tx.decrypt(c.getAllowanceStandardEnc()));
            }
            d.setSocialInsuranceLocation(c.getSocialInsuranceLocation());
        }
    }

    private String decryptMasked(String cipher, Set<String> roles) {
        if (cipher == null) return null;
        String plain = tx.decrypt(cipher);
        return policy.canSeeIdCardAndBank(roles) ? plain : maskPhone(plain);
    }

    private Collection<UUID> resolveDeptIds(UUID departmentId, boolean includeSubtree) {
        if (departmentId == null) return null;
        if (!includeSubtree) return List.of(departmentId);
        return deptRepo.findSubtree(departmentId).stream().map(Department::getId).toList();
    }

    private Employee requireEmployee(UUID id) {
        return empRepo.findById(id).filter(e -> !e.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "员工不存在"));
    }

    private EmployeeListItem toList(Employee e) {
        return new EmployeeListItem(e.getId(), e.getCode(), e.getFullName(), e.getGender(),
                e.getDepartment() == null ? null : e.getDepartment().getName(),
                e.getPosition() == null ? null : e.getPosition().getName(),
                e.getStatus(), e.getEmploymentType(), e.getHireDate());
    }

    private NestedDtos.EmploymentHistoryDto toHistory(EmploymentHistory h) {
        String fromName = h.getFromDepartmentId() == null ? null
                : deptRepo.findById(h.getFromDepartmentId()).map(Department::getName).orElse(null);
        String toName = h.getToDepartmentId() == null ? null
                : deptRepo.findById(h.getToDepartmentId()).map(Department::getName).orElse(null);
        return new NestedDtos.EmploymentHistoryDto(h.getId(), h.getEventType(),
                h.getFromDepartmentId(), h.getToDepartmentId(), fromName, toName,
                h.getEventDate(), h.getRemark());
    }

    private static LocalDate probationEnd(LocalDate hire, Integer months) {
        return (hire == null || months == null) ? null : hire.plusMonths(months);
    }

    private static String maskPhone(String phone) {
        if (phone == null || phone.length() < 7) return phone;
        return phone.substring(0, 3) + "****" + phone.substring(phone.length() - 4);
    }

    private static String joinTypeAndReason(String type, String reason) {
        if (isBlank(type)) return reason;
        if (isBlank(reason)) return type;
        return type + "：" + reason;
    }

    private static boolean hasAnySalary(OnboardingRequest.Compensation c) {
        return !isBlank(c.baseSalary()) || !isBlank(c.perfSalary()) || !isBlank(c.socialInsuranceBase())
                || !isBlank(c.housingFundBase()) || !isBlank(c.allowanceStandard());
    }

    private static boolean isBlank(String s) {
        return s == null || s.isBlank();
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
