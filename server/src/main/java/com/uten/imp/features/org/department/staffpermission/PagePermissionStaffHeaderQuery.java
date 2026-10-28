package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.features.org.employee.EmployeeHeaderQuery;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Read-only header criteria stay inside the existing manageable employee relation. */
record PagePermissionStaffHeaderQuery(EmployeeHeaderQuery query) {
    private static final Map<String,String> TEXT_FIELDS=Map.of(
            "name","COALESCE(employee.full_name,'未命名员工')", "employeeCode","employee.code",
            "department","department.name", "position","position.name");
    static PagePermissionStaffHeaderQuery read(Map<String,String> parameters) {
        return new PagePermissionStaffHeaderQuery(EmployeeHeaderQuery.read(parameters,new EmployeeHeaderQuery.Columns(
                TEXT_FIELDS,"COALESCE(account.status,'notProvisioned')","employee.status","employee.id",
                Set.copyOf(com.uten.imp.features.org.employee.EmploymentStatusPolicy.CURRENT_EMPLOYEE_STATUSES))));
    }
    boolean active() { return query.active(); }
    String sort() { return query.sort(); }
    void append(StringBuilder filter,List<Object> parameters) {
        query.append(filter,parameters);
    }
    String ordering() { return query.ordering(); }
}
