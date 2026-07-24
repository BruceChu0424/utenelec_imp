package com.uten.imp.features.visitor;

import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorListItem;
import com.uten.imp.security.TxSessionVars;
import org.springframework.stereotype.Component;

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
        return new VisitorListItem(
                a.getId(), a.getVisitorName(), a.getCompany(), a.getVisitPurpose(),
                host[0], host[1],
                a.getPlannedVisitAt(), a.getPlannedLeaveAt(),
                a.getStatus(), a.getAppliedAt(), a.getApprovedAt(),
                a.isHasVehicle(), tx.decrypt(a.getPlateNoEnc()));
    }
}
