package com.uten.imp.features.org.employee;

import com.uten.imp.common.identity.CurrentEmployeeStatusPolicy;

import java.util.List;

/**
 * 员工在职状态的唯一权威口径。
 *
 * <p>权限解析、员工目录、组织范围与各业务"在职员工"查询全部以此集合为准。
 * 原生 SQL（WorkforceOverviewQuery、DepartmentPermissionStaffQuery、DepartmentRepository、
 * ChainNoticeService、ExpenseApplicantQuery、PayrollEmployeeQuery 等）因文本块常量折叠
 * 仍以字面量镜像此列表——修改本类时必须同步核对上述 SQL，防止口径漂移。</p>
 */
public final class EmploymentStatusPolicy {

    /** 在职：正式在职、试用期、留职停薪均视为"当前员工"。 */
    public static final List<String> CURRENT_EMPLOYEE_STATUSES =
            CurrentEmployeeStatusPolicy.CURRENT_EMPLOYEE_STATUSES;

    public static boolean isCurrentEmployee(String status) {
        return CurrentEmployeeStatusPolicy.isCurrentEmployee(status);
    }

    private EmploymentStatusPolicy() {
    }
}
