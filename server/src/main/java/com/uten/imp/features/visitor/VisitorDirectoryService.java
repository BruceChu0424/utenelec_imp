package com.uten.imp.features.visitor;

import com.uten.imp.features.org.department.Department;
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
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 被访人目录（访客在申请页选择接待人/部门）。
 * 只返回在职员工（active/probation/onLeave），**排除离职 resigned**；仅 id/姓名/部门，无敏感字段。
 */
@Service
@RequiredArgsConstructor
public class VisitorDirectoryService {

    /** 公司根节点的 level：访客选不到公司本身，只能选下属部门。 */
    private static final String COMPANY_LEVEL = "公司";

    private final EmployeeRepository employeeRepo;
    private final DepartmentRepository departmentRepo;

    public List<DepartmentDirectoryItem> listDepartments() {
        return departmentRepo.findAll().stream()
                // 软删部门不泄露给访客（与 DepartmentService.tree 的过滤一致）
                .filter(d -> !d.isDeleted())
                // 排除公司根节点：访客接待必须选到下属部门，否则按部门查员工会得到空集。
                .filter(d -> !COMPANY_LEVEL.equals(d.getLevel()))
                // 与部门管理页一致：sortOrder 优先（null 兜底排最后），同级按名称。
                .sorted(Comparator
                        .comparing(Department::getSortOrder, Comparator.nullsLast(Comparator.naturalOrder()))
                        .thenComparing(Department::getName))
                .map(d -> new DepartmentDirectoryItem(
                        d.getId(),
                        d.getName(),
                        d.getLevel(),
                        d.getParent() == null ? null : d.getParent().getId()))
                .toList();
    }

    public List<EmployeeDirectoryItem> listEmployees(UUID departmentId, String keyword) {
        // departmentId 命中时，按"该部门 + 全部子部门"匹配——这样选父部门
        // （如总经办）也能看到所有下属员工；选叶子就只看叶子。
        // 选错层级不会让访客卡在"该部门无员工"。
        final Set<UUID> departmentScope = (departmentId == null)
                ? null
                : departmentRepo.findSubtree(departmentId).stream()
                        .map(Department::getId)
                        .collect(Collectors.toSet());

        Specification<Employee> spec = (root, query, cb) -> {
            Predicate p = cb.and(cb.equal(root.get("deleted"), false),
                    root.get("status").in("active", "probation", "onLeave"));
            if (departmentScope != null) {
                p = cb.and(p, root.get("department").get("id").in(departmentScope));
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
