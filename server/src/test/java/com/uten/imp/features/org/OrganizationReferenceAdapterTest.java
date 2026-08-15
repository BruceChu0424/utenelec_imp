package com.uten.imp.features.org;

import com.uten.imp.application.port.OrganizationReferencePort;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class OrganizationReferenceAdapterTest {

    private final EmployeeRepository employees = mock(EmployeeRepository.class);
    private final DepartmentRepository departments = mock(DepartmentRepository.class);
    private final OrganizationReferenceAdapter adapter =
            new OrganizationReferenceAdapter(employees, departments);

    @Test
    void exposesOnlyImmutableActiveIdentityProjection() {
        Department production = department("DEPT_PROD", "生产部", null);
        Department workshop = department("WS01", "一车间", production);
        Employee employee = new Employee();
        employee.setLegacyId(17);
        employee.setDepartment(workshop);

        when(employees.findById(employee.getId())).thenReturn(Optional.of(employee));
        when(departments.findById(workshop.getId())).thenReturn(Optional.of(workshop));

        assertThat(adapter.findActiveEmployee(employee.getId()))
                .contains(new OrganizationReferencePort.EmployeeReference(
                        employee.getId(), 17, workshop.getId()));
        assertThat(adapter.findActiveDepartment(workshop.getId()))
                .contains(new OrganizationReferencePort.DepartmentReference(
                        workshop.getId(), "WS01", "一车间",
                        production.getId(), "DEPT_PROD"));
    }

    @Test
    void childrenAndBatchNamesExcludeSoftDeletedDepartments() {
        Department production = department("DEPT_PROD", "生产部", null);
        Department active = department("WS01", "一车间", production);
        Department deleted = department("WS02", "二车间", production);
        deleted.setDeleted(true);

        when(departments.findByCodeAndDeletedFalse("DEPT_PROD"))
                .thenReturn(Optional.of(production));
        when(departments.findByParentIdOrderBySortOrderAscNameAsc(production.getId()))
                .thenReturn(List.of(active, deleted));
        when(departments.findAllById(any())).thenReturn(List.of(active, deleted));

        assertThat(adapter.findActiveChildrenOfDepartmentCode("DEPT_PROD"))
                .extracting(OrganizationReferencePort.DepartmentReference::id)
                .containsExactly(active.getId());
        assertThat(adapter.findActiveDepartmentNames(List.of(active.getId(), deleted.getId())))
                .isEqualTo(Map.of(active.getId(), "一车间"));
    }

    private static Department department(String code, String name, Department parent) {
        Department department = new Department();
        department.setCode(code);
        department.setName(name);
        department.setParent(parent);
        return department;
    }
}
