package com.uten.imp.features.org.employee;

import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/**
 * 员工兼职部门维护（V459）。回显随员工查看权限；改写要求员工编辑权限
 * （兼职并入权限合成，写库即由触发器吊销旧 token）。
 */
@RestController
@RequestMapping("/api/org/employees/{employeeId}/secondary-departments")
public class EmployeeSecondaryDepartmentController {

    private final EmployeeSecondaryDepartmentService service;

    public EmployeeSecondaryDepartmentController(EmployeeSecondaryDepartmentService service) {
        this.service = service;
    }

    @GetMapping
    @PreAuthorize("hasAuthority('employee:view')")
    public java.util.Map<String, Object> list(@PathVariable UUID employeeId) {
        return java.util.Map.of("items", service.listForEmployee(employeeId));
    }

    @PutMapping
    @PreAuthorize("hasAuthority('employee:edit')")
    public java.util.Map<String, Object> replace(
            @PathVariable UUID employeeId,
            @RequestBody List<EmployeeSecondaryDepartmentService.SecondaryDepartmentInput> items) {
        return java.util.Map.of("items", service.replace(employeeId, items));
    }
}
