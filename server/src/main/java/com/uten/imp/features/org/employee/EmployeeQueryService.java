package com.uten.imp.features.org.employee;

import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.dto.EmployeeDetail;
import com.uten.imp.features.org.employee.dto.EmployeeListItem;
import com.uten.imp.features.org.employee.dto.NestedDtos;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DataAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.common.util.Strings.maskPhone;

/** 员工档案查询：列表（Specification 摘要）与详情组装（按角色脱敏）。 */
@Service
@RequiredArgsConstructor
public class EmployeeQueryService {

    private final EmployeeRepository empRepo;
    private final EmployeeSensitiveRepository sensitiveRepo;
    private final EmployeeCompensationRepository compensationRepo;
    private final EmergencyContactRepository emergencyRepo;
    private final EmployeeCredentialRepository credentialRepo;
    private final EmployeeEducationRepository educationRepo;
    private final EmployeeContractRepository contractRepo;
    private final EmploymentHistoryRepository historyRepo;
    private final DepartmentRepository deptRepo;
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
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.ASC, "code"));
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

        // 证书 / 学历（非第三方 PII，全角色可见，与基础档案同级）
        d.setCertificates(credentialRepo.findByEmployeeId(id).stream()
                .map(x -> new NestedDtos.CredentialDto(x.getId(), x.getType(), x.getName(),
                        x.getCertNo(), x.getIssuedAt(), x.getExpiresAt()))
                .toList());
        d.setEducations(educationRepo.findByEmployeeIdOrderByEndDateDesc(id).stream()
                .map(x -> new NestedDtos.EducationDto(x.getId(), x.getDegree(), x.getSchool(),
                        x.getMajor(), x.getStartDate(), x.getEndDate()))
                .toList());

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

    // ===== 辅助（同包共享给 Command/Onboarding） =====

    Employee requireEmployee(UUID id) {
        return empRepo.findById(id).filter(e -> !e.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "员工不存在"));
    }

    NestedDtos.EmploymentHistoryDto toHistory(EmploymentHistory h) {
        String fromName = h.getFromDepartmentId() == null ? null
                : deptRepo.findById(h.getFromDepartmentId()).map(Department::getName).orElse(null);
        String toName = h.getToDepartmentId() == null ? null
                : deptRepo.findById(h.getToDepartmentId()).map(Department::getName).orElse(null);
        return new NestedDtos.EmploymentHistoryDto(h.getId(), h.getEventType(),
                h.getFromDepartmentId(), h.getToDepartmentId(), fromName, toName,
                h.getEventDate(), h.getRemark());
    }

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

    private EmployeeListItem toList(Employee e) {
        return new EmployeeListItem(e.getId(), e.getCode(), e.getFullName(), e.getGender(),
                e.getDepartment() == null ? null : e.getDepartment().getName(),
                e.getPosition() == null ? null : e.getPosition().getName(),
                e.getStatus(), e.getEmploymentType(), e.getHireDate());
    }

    private static LocalDate probationEnd(LocalDate hire, Integer months) {
        return (hire == null || months == null) ? null : hire.plusMonths(months);
    }
}
