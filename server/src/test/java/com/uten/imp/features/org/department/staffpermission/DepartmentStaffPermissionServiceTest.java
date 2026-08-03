package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.jpa.repository.Query;

import java.lang.reflect.Method;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class DepartmentStaffPermissionServiceTest {

    @Mock private EmployeeRepository employeeRepo;
    @Mock private DepartmentRepository departmentRepo;
    @Mock private UserAccountRepository userAccountRepo;
    @Mock private DepartmentPermissionRepository departmentPermissionRepo;
    @Mock private PermissionRepository permissionRepo;
    @Mock private UserPermissionOverrideRepository overrideRepo;
    @Mock private RefreshTokenRepository refreshTokenRepo;
    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private TxSessionVars tx;
    @Mock private PermissionResolver permissionResolver;

    @InjectMocks
    private DepartmentStaffPermissionService service;

    @Test
    void explicitTargetWithinManagementScopeIsAccepted() {
        UUID managerId = UUID.randomUUID();
        Department ownDepartment = department("MFG_CENTER", "管理中心");
        Department targetDepartment = department("DEPT_ENG", "一级部门");
        Employee manager = employee(managerId, ownDepartment);
        when(currentUser.requireEmployeeId()).thenReturn(managerId);
        when(employeeRepo.findById(managerId)).thenReturn(Optional.of(manager));
        when(departmentRepo.findById(targetDepartment.getId()))
                .thenReturn(Optional.of(targetDepartment));
        when(departmentRepo.isWithinManagerScope(targetDepartment.getId(), managerId))
                .thenReturn(true);

        assertSame(targetDepartment, service.requireManagedDepartment(targetDepartment.getId()));
    }

    @Test
    void targetOutsideManagementScopeIsRejected() {
        UUID managerId = UUID.randomUUID();
        Department ownDepartment = department("DEPT_HR", "一级部门");
        Department targetDepartment = department("DEPT_FIN", "一级部门");
        Employee manager = employee(managerId, ownDepartment);
        when(currentUser.requireEmployeeId()).thenReturn(managerId);
        when(employeeRepo.findById(managerId)).thenReturn(Optional.of(manager));
        when(departmentRepo.findById(targetDepartment.getId()))
                .thenReturn(Optional.of(targetDepartment));
        when(departmentRepo.isWithinManagerScope(targetDepartment.getId(), managerId))
                .thenReturn(false);

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.requireManagedDepartment(targetDepartment.getId()));

        assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        assertThat(error.getMessage()).contains("管理中心负责人可管理中心下属部门");
    }

    @Test
    void omittedTargetKeepsLegacyOwnDepartmentBehavior() {
        UUID managerId = UUID.randomUUID();
        Department ownDepartment = department("DEPT_HR", "一级部门");
        Employee manager = employee(managerId, ownDepartment);
        when(currentUser.requireEmployeeId()).thenReturn(managerId);
        when(employeeRepo.findById(managerId)).thenReturn(Optional.of(manager));
        when(departmentRepo.findById(ownDepartment.getId()))
                .thenReturn(Optional.of(ownDepartment));
        when(departmentRepo.isWithinManagerScope(ownDepartment.getId(), managerId))
                .thenReturn(true);

        assertSame(ownDepartment, service.requireManagedDepartment(null));
    }

    @Test
    void centerManagerCannotRevokeTargetDepartmentBaselinePermission() {
        UUID managerId = UUID.randomUUID();
        UUID targetEmployeeId = UUID.randomUUID();
        Department center = department("MFG_CENTER", "管理中心");
        Department targetDepartment = department("DEPT_ENG", "一级部门");
        Employee manager = employee(managerId, center);
        Employee target = employee(targetEmployeeId, targetDepartment);
        Permission permission = new Permission();
        permission.setCode("employee:edit");
        when(currentUser.requireEmployeeId()).thenReturn(managerId);
        when(employeeRepo.findById(targetEmployeeId)).thenReturn(Optional.of(target));
        when(employeeRepo.findById(managerId)).thenReturn(Optional.of(manager));
        when(departmentRepo.findById(targetDepartment.getId()))
                .thenReturn(Optional.of(targetDepartment));
        when(departmentRepo.isWithinManagerScope(targetDepartment.getId(), managerId))
                .thenReturn(true);
        when(permissionRepo.findByCode("employee:edit"))
                .thenReturn(Optional.of(permission));
        when(departmentPermissionRepo.findPermissionCodesByDepartmentIdWithAncestors(
                targetDepartment.getId()))
                .thenReturn(List.of("employee:edit"));

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.setStaffOverride(
                        targetEmployeeId, "employee:edit", "revoke"));

        assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        assertThat(error.getMessage()).contains("部门基线权限不可由负责人修改");
    }

    @Test
    void repositoryScopeUsesExplicitManagerAndOnlyCenterAncestors() throws Exception {
        Method method = DepartmentRepository.class.getMethod(
                "isWithinManagerScope", UUID.class, UUID.class);
        Query query = method.getAnnotation(Query.class);
        String sql = query.value().toLowerCase().replaceAll("\\s+", " ");

        assertThat(sql)
                .contains("with recursive ancestors")
                .contains("manager_id = :employeeid")
                .contains("id = :departmentid")
                .contains("level = '管理中心'")
                .doesNotContain("position");
    }

    private static Department department(String code, String level) {
        Department department = new Department();
        department.setCode(code);
        department.setName(code);
        department.setLevel(level);
        return department;
    }

    private static Employee employee(UUID id, Department department) {
        Employee employee = new Employee();
        employee.setId(id);
        employee.setDepartment(department);
        return employee;
    }
}
