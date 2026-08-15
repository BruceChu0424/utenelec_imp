package com.uten.imp.features.org;

import com.uten.imp.application.port.OrganizationReferencePort;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.EmployeeRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/** Organization-owned adapter for cross-feature UUID validation and compact display projections. */
@Component
@RequiredArgsConstructor
public class OrganizationReferenceAdapter implements OrganizationReferencePort {

    private final EmployeeRepository employees;
    private final DepartmentRepository departments;

    @Override
    @Transactional(readOnly = true)
    public Optional<EmployeeReference> findActiveEmployee(UUID employeeId) {
        if (employeeId == null) return Optional.empty();
        return employees.findById(employeeId)
                .filter(employee -> !employee.isDeleted())
                .map(employee -> new EmployeeReference(
                        employee.getId(), employee.getLegacyId(),
                        employee.getDepartment() == null ? null : employee.getDepartment().getId()));
    }

    @Override
    @Transactional(readOnly = true)
    public Optional<DepartmentReference> findActiveDepartment(UUID departmentId) {
        if (departmentId == null) return Optional.empty();
        return departments.findById(departmentId)
                .filter(department -> !department.isDeleted())
                .map(OrganizationReferenceAdapter::reference);
    }

    @Override
    @Transactional(readOnly = true)
    public Optional<DepartmentReference> findActiveDepartmentByCode(String code) {
        if (code == null || code.isBlank()) return Optional.empty();
        return departments.findByCodeAndDeletedFalse(code.trim())
                .map(OrganizationReferenceAdapter::reference);
    }

    @Override
    @Transactional(readOnly = true)
    public List<DepartmentReference> findActiveChildrenOfDepartmentCode(String parentCode) {
        Department parent = departments.findByCodeAndDeletedFalse(parentCode).orElse(null);
        if (parent == null) return List.of();
        return departments.findByParentIdOrderBySortOrderAscNameAsc(parent.getId()).stream()
                .filter(department -> !department.isDeleted())
                .map(OrganizationReferenceAdapter::reference)
                .toList();
    }

    @Override
    @Transactional(readOnly = true)
    public Map<UUID, String> findActiveDepartmentNames(Collection<UUID> departmentIds) {
        if (departmentIds == null || departmentIds.isEmpty()) return Map.of();
        Map<UUID, String> result = new LinkedHashMap<>();
        departments.findAllById(departmentIds).stream()
                .filter(department -> !department.isDeleted())
                .forEach(department -> result.put(department.getId(), department.getName()));
        return Map.copyOf(result);
    }

    private static DepartmentReference reference(Department department) {
        Department parent = department.getParent();
        return new DepartmentReference(
                department.getId(),
                department.getCode(),
                department.getName(),
                parent == null ? null : parent.getId(),
                parent == null ? null : parent.getCode());
    }
}
