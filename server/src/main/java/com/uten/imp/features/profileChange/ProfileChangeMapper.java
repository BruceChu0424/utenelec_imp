package com.uten.imp.features.profilechange;

import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.profilechange.dto.ProfileChangeDto;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

/** 批次折叠与 BatchDetail 组装（员工/审批人姓名批量回填，避免逐条 findById 的 N+1）。 */
@Component
public class ProfileChangeMapper {

    private final EmployeeRepository employeeRepo;
    private final ProfileFieldApplier applier;

    public ProfileChangeMapper(EmployeeRepository employeeRepo, ProfileFieldApplier applier) {
        this.employeeRepo = employeeRepo;
        this.applier = applier;
    }

    /** 批量取员工（id → Employee），缺失的 id 不在 map 中。 */
    public Map<UUID, Employee> employeesById(Iterable<UUID> ids) {
        Set<UUID> distinct = new LinkedHashSet<>();
        ids.forEach(distinct::add);
        distinct.remove(null);
        if (distinct.isEmpty()) return Map.of();
        return employeeRepo.findAllById(distinct).stream()
                .collect(Collectors.toMap(Employee::getId, Function.identity()));
    }

    /** 同批次多字段整体状态：applied / approved / rejected / pending / cancelled。 */
    public String aggregateStatus(List<ProfileChangeRequest> rs) {
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

    public ProfileChangeDto.BatchDetail toBatchDetail(List<ProfileChangeRequest> rs) {
        ProfileChangeRequest first = rs.get(0);
        // 批量回填姓名：一次查齐 员工本人 + 全部提交人 + 全部审批人
        Set<UUID> peopleIds = new LinkedHashSet<>();
        peopleIds.add(first.getEmployeeId());
        for (ProfileChangeRequest r : rs) {
            peopleIds.add(r.getSubmittedBy());
            if (r.getReviewedBy() != null) peopleIds.add(r.getReviewedBy());
        }
        Map<UUID, Employee> people = employeesById(peopleIds);
        Function<UUID, String> nameOf = id -> id == null ? null
                : people.getOrDefault(id, null) == null ? null : people.get(id).getFullName();

        Employee emp = people.get(first.getEmployeeId());
        List<ProfileChangeDto.Item> items = new ArrayList<>();
        for (ProfileChangeRequest r : rs) {
            String oldVal = r.getOldValueEnc();
            String newVal = r.getNewValueEnc();
            boolean encrypted = ProfileFieldPolicy.isEmergencyContactSubfield(r.getFieldCode())
                    || ProfileFieldPolicy.Field.PHONE.equals(r.getFieldCode());
            String oldOut = encrypted && oldVal != null && oldVal.contains(":") ? applier.safeDecrypt(oldVal) : oldVal;
            String newOut = encrypted && newVal != null && newVal.contains(":") ? applier.safeDecrypt(newVal) : newVal;
            items.add(new ProfileChangeDto.Item(
                    r.getId(), r.getBatchId(), r.getFieldCode(), r.getFieldLabel(), r.getFieldGroup(),
                    oldOut, newOut,
                    r.getStatus(),
                    r.getSubmittedBy(),
                    nameOf.apply(r.getSubmittedBy()),
                    r.getSubmittedAt(),
                    r.getReviewedBy(),
                    r.getReviewedBy() == null ? null : nameOf.apply(r.getReviewedBy()),
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
                nameOf.apply(first.getSubmittedBy()),
                first.getReviewedAt(),
                first.getReviewedBy() == null ? null : nameOf.apply(first.getReviewedBy()),
                first.getReviewComment()
        );
    }
}
