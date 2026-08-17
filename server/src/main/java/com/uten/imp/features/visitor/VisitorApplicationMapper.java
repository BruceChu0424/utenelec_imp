package com.uten.imp.features.visitor;

import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorListItem;
import com.uten.imp.security.TxSessionVars;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/** 访客申请装配：被访人信息 / 列表项（VisitorApplicationService 与各审批 Service 共用）。 */
@Component
public class VisitorApplicationMapper {

    private final EmployeeRepository employeeRepo;
    private final TxSessionVars tx;

    public VisitorApplicationMapper(EmployeeRepository employeeRepo, TxSessionVars tx) {
        this.employeeRepo = employeeRepo;
        this.tx = tx;
    }

    /** [hostName, hostDepartmentName]，无被访人时 [null, null]。 */
    public String[] hostInfo(VisitorApplication a) {
        if (a.getHostEmployeeId() == null) return new String[]{null, null};
        return employeeRepo.findById(a.getHostEmployeeId())
                .map(e -> new String[]{e.getFullName(),
                        e.getDepartment() == null ? null : e.getDepartment().getName()})
                .orElse(new String[]{null, null});
    }

    public VisitorListItem toListItem(VisitorApplication a) {
        String[] host = hostInfo(a);
        return toListItem(a, host);
    }

    /**
     * 批量装配一页列表。员工和部门只执行一次查询，避免每条访客申请各触发查询。
     */
    public List<VisitorListItem> toListItems(List<VisitorApplication> applications) {
        Set<UUID> hostIds = applications.stream()
                .map(VisitorApplication::getHostEmployeeId)
                .filter(java.util.Objects::nonNull)
                .collect(Collectors.toSet());
        Map<UUID, String[]> hosts = hostIds.isEmpty()
                ? Map.of()
                : employeeRepo.findAllWithDepartmentByIdIn(hostIds).stream()
                        .collect(Collectors.toMap(
                                employee -> employee.getId(),
                                employee -> new String[]{
                                        employee.getFullName(),
                                        employee.getDepartment() == null
                                                ? null
                                                : employee.getDepartment().getName()
                                },
                                (first, ignored) -> first));
        return applications.stream()
                // hosts 可能为空 Map.of()（不可变），null key 的 get/getOrDefault 会抛 NPE，先判空。
                .map(application -> toListItem(
                        application,
                        application.getHostEmployeeId() == null
                                ? new String[]{null, null}
                                : hosts.getOrDefault(
                                        application.getHostEmployeeId(),
                                        new String[]{null, null})))
                .toList();
    }

    private VisitorListItem toListItem(VisitorApplication a, String[] host) {
        return new VisitorListItem(
                a.getId(), a.getVisitorName(), a.getCompany(), a.getVisitPurpose(),
                host[0], host[1],
                a.getPlannedVisitAt(), a.getPlannedLeaveAt(),
                a.getStatus(), a.getAppliedAt(), a.getApprovedAt(),
                a.isHasVehicle(), tx.decrypt(a.getPlateNoEnc()));
    }
}
