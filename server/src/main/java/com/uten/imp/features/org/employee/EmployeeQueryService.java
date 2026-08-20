package com.uten.imp.features.org.employee;

import com.uten.imp.application.port.AttachmentAccessPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.dto.EmployeeDetail;
import com.uten.imp.features.org.employee.dto.EmployeeListItem;
import com.uten.imp.features.org.employee.dto.NestedDtos;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DataAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.Collection;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.common.util.Strings.maskPhone;

/** 员工档案查询：列表摘要与详情组装（按权限点脱敏）。 */
@Service
@RequiredArgsConstructor
public class EmployeeQueryService {

    private final EmployeeRepository empRepo;
    private final EmployeeListQuery employeeListQuery;
    private final EmployeeSensitiveRepository sensitiveRepo;
    private final EmployeeCompensationRepository compensationRepo;
    private final EmergencyContactRepository emergencyRepo;
    private final EmployeeCredentialRepository credentialRepo;
    private final EmployeeEducationRepository educationRepo;
    private final EmployeeContractRepository contractRepo;
    private final EmploymentHistoryRepository historyRepo;
    private final DepartmentRepository deptRepo;
    private final UserAccountRepository userRepo;
    private final TxSessionVars tx;
    private final DataAccessPolicy policy;
    private final SecurityContextCurrentUser currentUser;
    private final EmployeeVehiclePhoneService vehiclePhoneService;
    private final AttachmentAccessPort attachmentAccess;

    // ===== 列表（摘要，无敏感） =====
    @Transactional(readOnly = true)
    public PageResponse<EmployeeListItem> list(int page, int size, String search,
                                                Set<String> statuses, UUID departmentId, boolean includeSubtree) {
        Collection<UUID> deptIds = resolveDeptIds(departmentId, includeSubtree);
        EmployeeListQuery.Result result = employeeListQuery.query(
                page,
                size,
                search,
                statuses,
                deptIds,
                departmentId != null);
        return new PageResponse<>(
                result.items(),
                result.page(),
                result.size(),
                result.total(),
                result.totalPages());
    }

    // ===== 详情（按权限点脱敏，ADR-011 后不再按角色） =====
    /** 员工详情：字段级按权限点脱敏——身份证/银行/手机明文需 PII 权限，无 employee:pii:view 时人口属性/地址/生日清空，备用手机号按主号规则掩码。证书/学历非第三方 PII，随基础档案全可见。 */
    @Transactional(readOnly = true)
    public EmployeeDetail detail(UUID id) {
        tx.bind();
        Employee e = requireEmployee(id);
        Set<String> perms = currentUser.get().map(AuthUser::getPermissions).orElse(Set.of());
        EmployeeSensitive s = sensitiveRepo.findByEmployeeId(id).orElse(null);
        EmployeeCompensation c = compensationRepo.findByEmployeeId(id).orElse(null);

        EmployeeDetail d = new EmployeeDetail();
        d.setId(e.getId());
        d.setCode(e.getCode());
        d.setFullName(e.getFullName());
        d.setGender(e.getGender());
        d.setIdType(e.getIdType());
        d.setEthnicity(e.getEthnicity());
        // 出生日期/政治面貌/婚姻状况/户籍地址/居住地址/办公电话/邮箱 已加密存 sensitive，在 fillSensitive 解密填充。
        d.setDepartmentId(e.getDepartment() == null ? null : e.getDepartment().getId());
        d.setDepartmentName(e.getDepartment() == null ? null : e.getDepartment().getName());
        d.setPositionId(e.getPosition() == null ? null : e.getPosition().getId());
        d.setPositionName(e.getPosition() == null ? null : e.getPosition().getName());
        d.setPositionLevel(e.getPosition() == null ? null : e.getPosition().getLevel());
        int leaderRank = leaderRank(e);
        d.setDepartmentManager(leaderRank == 0);
        d.setLeaderRank(leaderRank);
        d.setSupervisorId(e.getSupervisor() == null ? null : e.getSupervisor().getId());
        d.setSupervisorName(e.getSupervisor() == null ? null : e.getSupervisor().getFullName());
        d.setHireDate(e.getHireDate());
        d.setConfirmedAt(e.getConfirmedAt());
        d.setStatus(e.getStatus());
        d.setEmploymentType(e.getEmploymentType());
        d.setWorkLocation(e.getWorkLocation());
        d.setSeatNo(e.getSeatNo());
        d.setAttendanceGroup(e.getAttendanceGroup());
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

        // 合同时间线（全部合同 + 到期天数/预警；null end_date=无固定期限）
        LocalDate today = BusinessTime.today();
        List<NestedDtos.ContractDto> contractDtos = contracts.stream()
                .map(ct -> {
                    Integer days = ct.getEndDate() == null ? null
                            : (int) ChronoUnit.DAYS.between(today, ct.getEndDate());
                    return new NestedDtos.ContractDto(ct.getId(), ct.getContractType(),
                            ct.getStartDate(), ct.getEndDate(), ct.getProbationMonths(),
                            ct.getSignOrder(), days,
                            days != null && days >= 0 && days <= 30,
                            days != null && days < 0);
                })
                .toList();
        d.setContracts(contractDtos);

        // 档案文件（CLEAN 附件；附件层按 EmployeeAttachmentAccessPolicy 校验）。
        // attachment:view 可被权限管理页按部门收回：无该权限点时降级为空列表，
        // 不能让整个员工详情 403（employee:view 与 attachment:view 是两个独立开关）。
        try {
            d.setAttachments(attachmentAccess.listVisible(EmployeeAttachmentAccessPolicy.OWNER_TYPE, id));
        } catch (ApiException attachmentDenied) {
            if (attachmentDenied.getCode() != ErrorCode.FORBIDDEN) {
                throw attachmentDenied;
            }
            d.setAttachments(List.of());
        }

        // 登录账号状态（离职冻结后 HR 在详情页可直接确认账号已停用）
        d.setAccountStatus(userRepo.findByEmployeeId(id)
                .map(u -> u.isDeleted() ? "disabled" : u.getStatus())
                .orElse(null));

        fillSensitive(d, s, c, perms);

        // 紧急联系人（phone 按权限点脱敏）
        List<NestedDtos.EmergencyContactDto> ec = emergencyRepo.findByEmployeeIdOrderBySortOrderAsc(id).stream()
                .map(x -> new NestedDtos.EmergencyContactDto(x.getId(), x.getName(),
                        decryptMasked(x.getPhoneEnc(), perms), x.getRelationship()))
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

        // 车辆（employee:view 可见，支撑「按车牌找人」）与备用手机号（掩码规则同主手机号）—— ADR-021
        d.setVehicles(vehiclePhoneService.listVehicles(id));
        boolean canSeePii = policy.canSeeIdCardAndBank(perms);
        d.setPhones(vehiclePhoneService.listPhones(id).stream()
                .map(p -> new NestedDtos.PhoneDto(p.id(), p.label(),
                        canSeePii ? p.phonePlain() : maskPhone(p.phonePlain())))
                .toList());

        // 隐私保护（M5/PIPL）：无 employee:pii:view 时不返回民族（人口属性）。
        // 地址/出生日期/婚姻/政治面貌已在 fillSensitive 按 pii:view 门控（无权限不填充）。
        if (!policy.canSeeIdCardAndBank(perms)) {
            d.setEthnicity(null);
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

    private void fillSensitive(EmployeeDetail d, EmployeeSensitive s, EmployeeCompensation c, Set<String> perms) {
        if (s != null) {
            String idPlain = tx.decrypt(s.getIdCardEnc());
            String phonePlain = tx.decrypt(s.getPhoneEnc());
            // 办公电话/邮箱：联系方式，对 employee:view 全可见（与原 entity 行为一致），仅存储改加密。
            if (s.getOfficePhoneEnc() != null) d.setOfficePhone(tx.decrypt(s.getOfficePhoneEnc()));
            if (s.getEmailEnc() != null) d.setEmail(tx.decrypt(s.getEmailEnc()));
            if (policy.canSeeIdCardAndBank(perms)) {
                d.setIdNumber(idPlain);
                d.setPhone(phonePlain);
                if (s.getBankAccountEnc() != null) d.setBankAccount(tx.decrypt(s.getBankAccountEnc()));
                if (s.getBankBranchEnc() != null) d.setBankBranch(tx.decrypt(s.getBankBranchEnc()));
                // V282 扩展 PII（地址/出生日期/婚姻/政治面貌）：仅 employee:pii:view 可见
                if (s.getHujiAddressEnc() != null) d.setHujiAddress(tx.decrypt(s.getHujiAddressEnc()));
                if (s.getResidenceAddressEnc() != null) d.setResidenceAddress(tx.decrypt(s.getResidenceAddressEnc()));
                if (s.getBirthDateEnc() != null) d.setBirthDate(parseDate(tx.decrypt(s.getBirthDateEnc())));
                if (s.getMaritalStatusEnc() != null) d.setMaritalStatus(tx.decrypt(s.getMaritalStatusEnc()));
                if (s.getPoliticalStatusEnc() != null) d.setPoliticalStatus(tx.decrypt(s.getPoliticalStatusEnc()));
            } else {
                d.setIdNumber(IdCardUtil.mask(idPlain));
                d.setPhone(maskPhone(phonePlain));
            }
        }
        if (c != null) {
            if (policy.canSeeSalary(perms)) {
                d.setBaseSalary(tx.decrypt(c.getBaseSalaryEnc()));
                d.setPerfSalary(tx.decrypt(c.getPerfSalaryEnc()));
                d.setSocialInsuranceBase(tx.decrypt(c.getSocialInsuranceBaseEnc()));
                d.setHousingFundBase(tx.decrypt(c.getHousingFundBaseEnc()));
                d.setAllowanceStandard(tx.decrypt(c.getAllowanceStandardEnc()));
                // 社保缴纳地属薪酬信息（可推断缴费基数档位/劳动关系归属），同权限门控
                d.setSocialInsuranceLocation(c.getSocialInsuranceLocation());
            }
        }
    }

    private String decryptMasked(String cipher, Set<String> perms) {
        if (cipher == null) return null;
        String plain = tx.decrypt(cipher);
        return policy.canSeeIdCardAndBank(perms) ? plain : maskPhone(plain);
    }

    /** 解析加密存储的 ISO 出生日期（yyyy-MM-dd）为 LocalDate；非法或空返回 null。 */
    private static LocalDate parseDate(String iso) {
        if (iso == null || iso.isBlank()) return null;
        try {
            return LocalDate.parse(iso);
        } catch (Exception e) {
            return null;
        }
    }

    private Collection<UUID> resolveDeptIds(UUID departmentId, boolean includeSubtree) {
        if (departmentId == null) return null;
        if (!includeSubtree) return List.of(departmentId);
        return deptRepo.findSubtree(departmentId).stream().map(Department::getId).toList();
    }

    private int leaderRank(Employee employee) {
        if (employee.getDepartment() != null
                && employee.getDepartment().getManager() != null
                && employee.getId().equals(employee.getDepartment().getManager().getId())) {
            return 0;
        }
        String positionLevel = employee.getPosition() == null
                ? null
                : employee.getPosition().getLevel();
        if ("领导层".equals(positionLevel)) return 1;
        if ("班组管理".equals(positionLevel)) return 2;
        return 3;
    }

    private static LocalDate probationEnd(LocalDate hire, Integer months) {
        return (hire == null || months == null) ? null : hire.plusMonths(months);
    }
}
