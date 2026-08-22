package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class OrganizationPermissionManagementScopeServiceTest {

    @Mock private EmployeeRepository employeeRepo;
    @Mock private UserAccountRepository userAccountRepo;
    @Mock private DepartmentRepository departmentRepo;

    private OrganizationPermissionManagementScopeService service;

    @BeforeEach
    void setUp() {
        service = new OrganizationPermissionManagementScopeService(
                employeeRepo,
                userAccountRepo,
                departmentRepo);
    }

    @Test
    void activeSuperAdminWithoutEmployeeGetsCompanyAuthority() {
        AuthUser actor = actor(UUID.randomUUID(), null, true);
        UserAccount account = account(actor.getId(), null, true);
        account.setPermissionDelegationGeneration(9L);
        Department finance = department("DEPT_FIN", "一级部门", "/FIN/");
        Department company = department("COMPANY", "公司", "/COMPANY/");
        when(userAccountRepo.findById(actor.getId())).thenReturn(Optional.of(account));
        when(departmentRepo.findByDeletedFalseOrderBySortOrderAscNameAsc())
                .thenReturn(List.of(company, finance));
        when(departmentRepo.findById(finance.getId())).thenReturn(Optional.of(finance));

        var managed = service.managedDepartments(actor);
        var authority = service.resolveAuthority(actor, finance.getId());

        assertEquals(2, managed.size());
        assertEquals(company.getId(), managed.getFirst().departmentId());
        assertFalse(managed.getFirst().selectable());
        assertEquals(finance.getId(), managed.get(1).departmentId());
        assertTrue(managed.get(1).selectable());
        assertTrue(authority.isPresent());
        assertEquals(
                OrganizationPermissionManagementScopeService.AuthoritySource.SUPER_ADMIN,
                authority.orElseThrow().source());
        assertEquals(
                OrganizationPermissionManagementScopeService.AuthorityScope.COMPANY,
                authority.orElseThrow().scopeType());
        assertEquals(9L, authority.orElseThrow().version());
        verify(employeeRepo, never()).findById(
                org.mockito.ArgumentMatchers.any());
        verify(departmentRepo, never()).findManagedDepartments(
                org.mockito.ArgumentMatchers.any());
    }

    @Test
    void directCanonicalGmManagerGetsCompanyScopeWithGmGenerationSnapshot() {
        Department company = department("UTEN", "公司", "/UTEN/");
        Department gm = department("GM", "一级部门", "/UTEN/GM/");
        gm.setName("可变显示名称");
        gm.setParent(company);
        gm.setPermissionDelegationGeneration(23L);
        Department target = department("DEPT_FIN", "一级部门", "/UTEN/FIN/");
        target.setParent(company);
        Employee employee = employee(gm);
        gm.setManager(employee);
        AuthUser actor = actor(UUID.randomUUID(), employee.getId(), false);
        UserAccount account = account(actor.getId(), employee.getId(), false);
        when(userAccountRepo.findById(actor.getId())).thenReturn(Optional.of(account));
        when(employeeRepo.findById(employee.getId())).thenReturn(Optional.of(employee));
        when(departmentRepo.findByManagerId(employee.getId()))
                .thenReturn(List.of(gm));
        when(departmentRepo.findByDeletedFalseOrderBySortOrderAscNameAsc())
                .thenReturn(List.of(company, gm, target));
        when(departmentRepo.findById(target.getId())).thenReturn(Optional.of(target));
        when(departmentRepo.findManagerScopeDepartmentId(
                target.getId(), employee.getId()))
                .thenReturn(Optional.of(gm.getId()));
        when(departmentRepo.findById(gm.getId())).thenReturn(Optional.of(gm));

        var search = service.staffSearchAuthority(actor).orElseThrow();
        var managed = service.managedDepartments(actor);
        var authority = service.resolveAuthority(actor, target.getId()).orElseThrow();

        assertEquals(
                OrganizationPermissionManagementScopeService.StaffSearchScope
                        .EXECUTIVE_OFFICE_COMPANY,
                search.scope());
        assertEquals(3, managed.size());
        assertEquals(
                OrganizationPermissionManagementScopeService.AuthorityScope.COMPANY,
                authority.scopeType());
        assertEquals(gm.getId(), authority.rootDepartmentId());
        assertEquals(23L, authority.rootGeneration());
    }

    @Test
    void managementCenterManagerGetsSubtreeWithRootSnapshot() {
        Department center = department("CENTER_MFG", "管理中心", "/MFG/");
        center.setPermissionDelegationGeneration(17L);
        Department child = department("DEPT_PMC", "一级部门", "/MFG/PMC/");
        Employee employee = employee(center);
        center.setManager(employee);
        AuthUser actor = actor(UUID.randomUUID(), employee.getId(), false);
        UserAccount account = account(actor.getId(), employee.getId(), false);
        when(userAccountRepo.findById(actor.getId())).thenReturn(Optional.of(account));
        when(employeeRepo.findById(employee.getId())).thenReturn(Optional.of(employee));
        when(departmentRepo.findByManagerId(employee.getId()))
                .thenReturn(List.of(center));
        when(departmentRepo.findManagedDepartments(employee.getId()))
                .thenReturn(List.of(center, child));
        when(departmentRepo.findById(child.getId())).thenReturn(Optional.of(child));
        when(departmentRepo.findManagerScopeDepartmentId(
                child.getId(), employee.getId()))
                .thenReturn(Optional.of(center.getId()));
        when(departmentRepo.findById(center.getId())).thenReturn(Optional.of(center));

        var managed = service.managedDepartments(actor);
        var authority = service.resolveAuthority(actor, child.getId())
                .orElseThrow();

        assertEquals(2, managed.size());
        assertEquals(center.getId(), managed.get(1).authority().rootDepartmentId());
        assertEquals(
                OrganizationPermissionManagementScopeService.AuthoritySource
                        .DEPARTMENT_MANAGER,
                authority.source());
        assertEquals(center.getId(), authority.id());
        assertEquals(center.getId(), authority.rootDepartmentId());
        assertEquals(17L, authority.rootGeneration());
        assertEquals(
                OrganizationPermissionManagementScopeService.AuthorityScope.SUBTREE,
                authority.scopeType());
    }

    @Test
    void ordinaryDepartmentManagerGetsItsEntireActiveSubtree() {
        Department root = department("DEPT_SALES", "一级部门", "/SALES/");
        Department child = department("SALES_1", "二级班组", "/SALES/1/");
        Employee employee = employee(root);
        root.setManager(employee);
        AuthUser actor = actor(UUID.randomUUID(), employee.getId(), false);
        UserAccount account = account(actor.getId(), employee.getId(), false);
        when(userAccountRepo.findById(actor.getId())).thenReturn(Optional.of(account));
        when(employeeRepo.findById(employee.getId())).thenReturn(Optional.of(employee));
        when(departmentRepo.findByManagerId(employee.getId())).thenReturn(List.of(root));
        when(departmentRepo.findManagedDepartments(employee.getId()))
                .thenReturn(List.of(root, child));
        when(departmentRepo.findById(child.getId())).thenReturn(Optional.of(child));
        when(departmentRepo.findManagerScopeDepartmentId(
                child.getId(), employee.getId()))
                .thenReturn(Optional.of(root.getId()));
        when(departmentRepo.findById(root.getId())).thenReturn(Optional.of(root));

        var managed = service.managedDepartments(actor);

        assertEquals(List.of(root.getId(), child.getId()),
                managed.stream()
                        .map(OrganizationPermissionManagementScopeService
                                .ManagedDepartmentAuthority::departmentId)
                        .toList());
        assertEquals(
                OrganizationPermissionManagementScopeService.AuthorityScope.SUBTREE,
                managed.getFirst().authority().scopeType());
        assertEquals(root.getId(), service.resolveAuthority(actor, child.getId())
                .orElseThrow()
                .rootDepartmentId());
    }

    @Test
    void capabilityUsesExistsInsteadOfLoadingTheManagedTree() {
        Department department = department("DEPT_QA", "一级部门", "/QA/");
        Employee employee = employee(department);
        AuthUser actor = actor(UUID.randomUUID(), employee.getId(), false);
        UserAccount account = account(actor.getId(), employee.getId(), false);
        when(userAccountRepo.findById(actor.getId())).thenReturn(Optional.of(account));
        when(employeeRepo.findById(employee.getId())).thenReturn(Optional.of(employee));
        when(departmentRepo.existsManageableDepartmentByManagerId(employee.getId()))
                .thenReturn(true);

        assertTrue(service.hasManagementAuthority(actor));

        verify(departmentRepo, never()).findManagedDepartments(employee.getId());
        verify(departmentRepo, never()).findByManagerId(employee.getId());
    }

    @Test
    void currentEmployeeWithoutDepartmentManagerAssignmentHasNoAuthority() {
        Department home = department("DEPT_HR", "一级部门", "/HR/");
        Employee employee = employee(home);
        AuthUser actor = actor(UUID.randomUUID(), employee.getId(), false);
        UserAccount account = account(actor.getId(), employee.getId(), false);
        when(userAccountRepo.findById(actor.getId())).thenReturn(Optional.of(account));
        when(employeeRepo.findById(employee.getId())).thenReturn(Optional.of(employee));
        when(departmentRepo.existsManageableDepartmentByManagerId(employee.getId()))
                .thenReturn(false);

        assertFalse(service.hasManagementAuthority(actor));
    }

    @Test
    void resignedEmployeeCannotAcquireManagerAuthority() {
        Department home = department("DEPT_HR", "一级部门", "/HR/");
        Employee employee = employee(home);
        employee.setStatus("resigned");
        AuthUser actor = actor(UUID.randomUUID(), employee.getId(), false);
        UserAccount account = account(actor.getId(), employee.getId(), false);
        when(userAccountRepo.findById(actor.getId())).thenReturn(Optional.of(account));
        when(employeeRepo.findById(employee.getId())).thenReturn(Optional.of(employee));

        assertFalse(service.hasManagementAuthority(actor));

        verify(departmentRepo, never())
                .existsManageableDepartmentByManagerId(employee.getId());
    }

    @Test
    void invalidAccountFailsClosedBeforeOrganizationQueries() {
        Department department = department("DEPT_QA", "一级部门", "/QA/");
        UUID employeeId = UUID.randomUUID();
        AuthUser actor = actor(UUID.randomUUID(), employeeId, false);
        UserAccount disabled = account(actor.getId(), employeeId, false);
        disabled.setStatus("disabled");
        when(userAccountRepo.findById(actor.getId())).thenReturn(Optional.of(disabled));

        assertFalse(service.hasManagementAuthority(actor));
        assertTrue(service.managedDepartments(actor).isEmpty());
        assertTrue(service.resolveAuthority(actor, department.getId()).isEmpty());
        verify(employeeRepo, never()).findById(employeeId);
        verify(departmentRepo, never()).findById(department.getId());
        verify(departmentRepo, never()).findByManagerId(employeeId);
        verify(departmentRepo, never())
                .existsManageableDepartmentByManagerId(employeeId);
    }

    private static Employee employee(Department department) {
        Employee employee = new Employee();
        employee.setId(UUID.randomUUID());
        employee.setCode("E-" + employee.getId());
        employee.setFullName("Leader");
        employee.setStatus("active");
        employee.setDepartment(department);
        return employee;
    }

    private static UserAccount account(
            UUID userId,
            UUID employeeId,
            boolean superAdmin) {
        UserAccount account = new UserAccount();
        account.setId(userId);
        account.setEmployeeId(employeeId);
        account.setLoginAccount("U-" + userId);
        account.setStatus("active");
        account.setSuperAdmin(superAdmin);
        return account;
    }

    private static Department department(String code, String level, String path) {
        Department department = new Department();
        department.setId(UUID.randomUUID());
        department.setCode(code);
        department.setName(code);
        department.setLevel(level);
        department.setPath(path);
        return department;
    }

    private static AuthUser actor(UUID userId, UUID employeeId, boolean superAdmin) {
        return new AuthUser(
                userId,
                employeeId,
                "leader",
                Set.of(),
                Set.of(),
                false,
                true,
                superAdmin);
    }
}
