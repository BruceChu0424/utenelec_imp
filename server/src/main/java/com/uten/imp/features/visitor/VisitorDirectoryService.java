package com.uten.imp.features.visitor;

import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.visitor.dto.VisitorScanDto.DepartmentDirectoryItem;
import com.uten.imp.features.visitor.dto.VisitorScanDto.EmployeeDirectoryItem;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;

import java.util.Comparator;
import java.util.List;
import java.util.UUID;

/**
 * 被访人目录（访客在申请页选择接待人/部门）。
 * 只返回在职员工（active/probation/onLeave），**排除离职 resigned**；仅 id/姓名/部门，无敏感字段。
 */
@Service
@RequiredArgsConstructor
public class VisitorDirectoryService {

    private final EmployeeRepository employeeRepo;
    private final DepartmentRepository departmentRepo;

    public List<DepartmentDirectoryItem> listDepartments() {
        return departmentRepo.findAll().stream()
                .map(d -> new DepartmentDirectoryItem(d.getId(), d.getName()))
                .sorted(Comparator.comparing(DepartmentDirectoryItem::name))
                .toList();
    }

    public List<EmployeeDirectoryItem> listEmployees(UUID departmentId, String keyword) {
        Specification<Employee> spec = (root, query, cb) -> {
            Predicate p = cb.and(cb.equal(root.get("deleted"), false),
                    root.get("status").in("active", "probation", "onLeave"));
            if (departmentId != null) {
                p = cb.and(p, cb.equal(root.get("department").get("id"), departmentId));
            }
            if (keyword != null && !keyword.isBlank()) {
                String like = "%" + keyword.trim() + "%";
                p = cb.and(p, cb.or(cb.like(root.get("fullName"), like), cb.like(root.get("code"), like)));
            }
            return p;
        };
        return employeeRepo.findAll(spec).stream()
                .map(e -> new EmployeeDirectoryItem(e.getId(), e.getFullName(),
                        e.getDepartment() == null ? null : e.getDepartment().getName()))
                .sorted(Comparator.comparing(EmployeeDirectoryItem::name))
                .limit(50)
                .toList();
    }
}
