package com.uten.imp.features.visitor;

import com.uten.imp.features.visitor.dto.VisitorScanDto.DepartmentDirectoryItem;
import com.uten.imp.features.visitor.dto.VisitorScanDto.EmployeeDirectoryItem;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/** 被访人目录（authenticated：访客登录后选择接待人/部门）。 */
@RestController
@RequestMapping("/api/visitor/directory")
@RequiredArgsConstructor
public class VisitorDirectoryController {

    private final VisitorDirectoryService service;

    @GetMapping("/departments")
    @PreAuthorize("isAuthenticated()")
    public List<DepartmentDirectoryItem> departments() {
        return service.listDepartments();
    }

    @GetMapping("/employees")
    @PreAuthorize("isAuthenticated()")
    public List<EmployeeDirectoryItem> employees(@RequestParam(required = false) UUID departmentId,
                                                  @RequestParam(required = false) String keyword) {
        return service.listEmployees(departmentId, keyword);
    }
}
