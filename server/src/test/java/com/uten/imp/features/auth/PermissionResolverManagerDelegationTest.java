package com.uten.imp.features.auth;

import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistryTestFixture;
import com.uten.imp.features.org.department.staffpermission.PagePermissionDelegationFeatureGate;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSecondaryDepartmentRepository;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.ManagerPermissionDelegationRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.RolePermissionRepository;
import com.uten.imp.features.rbac.RoleRepository;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.security.PermissionDelegationPolicy;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class PermissionResolverManagerDelegationTest {

    private static final String CODE = "sales_order:view";

    @Mock private UserRoleRepository userRoleRepo;
    @Mock private RolePermissionRepository rolePermissionRepo;
    @Mock private PermissionRepository permissionRepo;
    @Mock private RoleRepository roleRepo;
    @Mock private DepartmentPermissionRepository departmentPermissionRepo;
    @Mock private UserPermissionOverrideRepository overrideRepo;
    @Mock private EmployeeRepository employeeRepo;
    @Mock private EmployeeSecondaryDepartmentRepository secondaryDeptRepo;
    @Mock private UserAccountRepository userAccountRepo;
    @Mock private DepartmentRepository departmentRepo;
    @Mock private ManagerPermissionDelegationRepository managerDelegationRepo;

    private PermissionResolver resolver;

    @BeforeEach
    void setUp() {
        resolver = resolverWithGate(true);
        when(roleRepo.findByCode("employee")).thenReturn(Optional.empty());
        lenient().when(secondaryDeptRepo.findDepartmentIdsByEmployeeId(any())).thenReturn(List.of());
    }

    private PermissionResolver resolverWithGate(boolean enabled) {
        return new PermissionResolver(
                userRoleRepo,
                rolePermissionRepo,
                permissionRepo,
                roleRepo,
                departmentPermissionRepo,
                overrideRepo,
                employeeRepo,
                secondaryDeptRepo,
                userAccountRepo,
                departmentRepo,
                managerDelegationRepo,
                new PermissionDelegationPolicy(),
                PermissionSurfaceRegistryTestFixture.registry(
                                Map.of("sales.order", Set.of(CODE))),
                new PagePermissionDelegationFeatureGate(enabled));
    }

    @Test
    void disabledFeatureGateNeverLoadsManagerDelegations() {
        Department department = new Department();
        department.setName("Sales");
        department.setCode("DEPT_SALES");
        department.setLevel("一级部门");
        Employee targetEmployee = employee(UUID.randomUUID(), department);
        UserAccount targetAccount = account(UUID.randomUUID(), targetEmployee.getId());
        when(employeeRepo.findById(targetEmployee.getId()))
                .thenReturn(Optional.of(targetEmployee));
        when(departmentPermissionRepo.findPermissionCodesByDepartmentIdsWithAncestors(
                List.of(department.getId()))).thenReturn(List.of());
        when(overrideRepo.findCodeAndEffectByUserId(targetAccount.getId()))
                .thenReturn(List.of());
        ManagerPermissionDelegationRepository.EnabledDelegationCandidate candidate =
                mock(ManagerPermissionDelegationRepository.EnabledDelegationCandidate.class);
        lenient().when(managerDelegationRepo.findEnabledCandidatesByUserId(
                targetAccount.getId())).thenReturn(List.of(candidate));

        PermissionResolver.PermBreakdown result =
                resolverWithGate(false).breakdownOf(targetAccount);

        assertTrue(result.managerGrants().isEmpty());
        assertFalse(result.effective().contains(CODE));
        verifyNoInteractions(managerDelegationRepo);
    }

    @Test
    void centralRevokeWinsEvenWhenManagerDelegationRemainsEligible() {
        Fixture fixture = eligibleDelegation();
        when(overrideRepo.findCodeAndEffectByUserId(fixture.targetAccount().getId()))
                .thenReturn(List.<Object[]>of(new Object[]{CODE, "revoke"}));

        PermissionResolver.PermBreakdown result =
                resolver.breakdownOf(fixture.targetAccount());

        assertTrue(result.managerGrants().contains(CODE));
        assertTrue(result.revokes().contains(CODE));
        assertFalse(result.effective().contains(CODE));
        assertEquals(result.effective(), resolver.permsOf(fixture.targetAccount()));
    }

    @Test
    void delegationFailsClosedWhenGrantorLosesManagerScope() {
        Fixture fixture = eligibleDelegation();
        when(departmentRepo.findManagerScopeDepartmentId(
                fixture.department().getId(), fixture.grantorEmployee().getId()))
                .thenReturn(Optional.empty());

        PermissionResolver.PermBreakdown result =
                resolver.breakdownOf(fixture.targetAccount());

        assertFalse(result.managerGrants().contains(CODE));
        assertFalse(result.effective().contains(CODE));
        assertTrue(result.contextualDelegationPresent(),
                "an enabled but temporarily invalid row must still bypass authority caching");
    }

    @Test
    void managerGrantCannotBeRedelegatedRecursively() {
        Fixture fixture = eligibleDelegation();

        PermissionResolver.PermBreakdown effective =
                resolver.breakdownOf(fixture.targetAccount());
        Set<String> ceiling = resolver.delegableCeilingOf(fixture.targetAccount());

        assertTrue(effective.effective().contains(CODE));
        assertTrue(effective.managerGrants().contains(CODE));
        assertFalse(ceiling.contains(CODE));
        assertEquals(effective.effective(), resolver.permsOf(fixture.targetAccount()));
    }

    @Test
    void pairedBreakdownsComputeBaseSourcesOnlyOnce() {
        Department department = new Department();
        department.setName("Sales");
        department.setCode("DEPT_SALES");
        department.setLevel("一级部门");
        Employee targetEmployee = employee(UUID.randomUUID(), department);
        UserAccount targetAccount = account(
                UUID.randomUUID(),
                targetEmployee.getId());
        when(employeeRepo.findById(targetEmployee.getId()))
                .thenReturn(Optional.of(targetEmployee));
        when(departmentPermissionRepo.findPermissionCodesByDepartmentIdsWithAncestors(
                List.of(department.getId()))).thenReturn(List.of());
        when(overrideRepo.findCodeAndEffectByUserId(targetAccount.getId()))
                .thenReturn(List.of());
        when(userAccountRepo.findById(targetAccount.getId()))
                .thenReturn(Optional.of(targetAccount));
        when(managerDelegationRepo.currentAuthorizationEpoch()).thenReturn(24L);
        when(managerDelegationRepo.findEnabledCandidatesByUserId(
                targetAccount.getId())).thenReturn(List.of());

        PermissionResolver.PermissionBreakdowns breakdowns =
                resolver.breakdownsOf(targetAccount);

        assertTrue(breakdowns.base().managerGrants().isEmpty());
        assertTrue(breakdowns.full().managerGrants().isEmpty());
        assertTrue(breakdowns.base().effective()
                .equals(breakdowns.full().effective()));
        verify(roleRepo, times(1)).findByCode("employee");
        verify(departmentPermissionRepo, times(1))
                .findPermissionCodesByDepartmentIdsWithAncestors(
                        List.of(department.getId()));
        verify(overrideRepo, times(1))
                .findCodeAndEffectByUserId(targetAccount.getId());
        verify(managerDelegationRepo, times(1))
                .findEnabledCandidatesByUserId(targetAccount.getId());
    }

    @Test
    void legacyUnknownGrantRemainsEffectiveButCannotAuthorizeRedelegation() {
        Fixture fixture = eligibleDelegation();
        when(overrideRepo.findCodeAndEffectByUserId(
                fixture.grantorAccount().getId()))
                .thenReturn(List.<Object[]>of(
                        new Object[]{CODE, "grant", "LEGACY_UNKNOWN"}));

        PermissionResolver.PermBreakdown target =
                resolver.breakdownOf(fixture.targetAccount());
        Set<String> grantorCeiling =
                resolver.delegableCeilingOf(fixture.grantorAccount());

        assertTrue(resolver.baseBreakdownOf(fixture.grantorAccount())
                .effective().contains(CODE));
        assertFalse(grantorCeiling.contains(CODE));
        assertFalse(target.managerGrants().contains(CODE));
    }

    @ParameterizedTest
    @EnumSource(CandidateMismatch.class)
    void everyGenerationAndScopeSnapshotMismatchFailsClosed(
            CandidateMismatch mismatch) {
        Fixture fixture = eligibleDelegation();
        ManagerPermissionDelegationRepository.EnabledDelegationCandidate candidate =
                fixture.candidate();
        switch (mismatch) {
            case TARGET_USER_GENERATION ->
                    when(candidate.getTargetUserGeneration()).thenReturn(99L);
            case TARGET_EMPLOYEE_GENERATION ->
                    when(candidate.getTargetEmployeeGeneration()).thenReturn(99L);
            case TARGET_DEPARTMENT_GENERATION ->
                    when(candidate.getTargetDepartmentGeneration()).thenReturn(99L);
            case TARGET_DEPARTMENT_ID ->
                    when(candidate.getDepartmentId()).thenReturn(UUID.randomUUID());
            case GRANTOR_USER_GENERATION ->
                    when(candidate.getGrantorUserGeneration()).thenReturn(99L);
            case GRANTOR_EMPLOYEE_GENERATION ->
                    when(candidate.getGrantorEmployeeGeneration()).thenReturn(99L);
            case GRANTOR_AUTH_VERSION ->
                    when(candidate.getGrantorAuthVersion()).thenReturn(99L);
            case AUTHORIZATION_EPOCH ->
                    when(candidate.getGrantorAuthorizationEpoch()).thenReturn(99L);
            case SCOPE_GENERATION ->
                    when(candidate.getScopeGeneration()).thenReturn(99L);
            case SCOPE_DEPARTMENT_ID ->
                    when(candidate.getScopeDepartmentId()).thenReturn(UUID.randomUUID());
            case LEGACY_SCOPE_SOURCE ->
                    when(candidate.getScopeSource()).thenReturn("LEGACY_UNVERIFIED");
            case UNEXPECTED_ASSIGNMENT_SHAPE ->
                    when(candidate.getScopeAssignmentId()).thenReturn(UUID.randomUUID());
        }

        PermissionResolver.PermBreakdown result =
                resolver.breakdownOf(fixture.targetAccount());

        assertFalse(result.managerGrants().contains(CODE));
        assertFalse(result.effective().contains(CODE));
    }

    @Test
    void retiredExplicitAssignmentNeverContributesAuthority() {
        Fixture fixture = eligibleDelegation();
        when(fixture.candidate().getScopeSource())
                .thenReturn("EXPLICIT_ASSIGNMENT");

        PermissionResolver.PermBreakdown result =
                resolver.breakdownOf(fixture.targetAccount());

        assertFalse(result.managerGrants().contains(CODE));
        assertFalse(result.effective().contains(CODE));
        verify(userAccountRepo, never()).findById(
                fixture.grantorAccount().getId());
        verify(departmentRepo, never()).findManagerScopeDepartmentId(
                fixture.department().getId(),
                fixture.grantorEmployee().getId());
    }

    @Test
    void activeSuperAdminGrantorDoesNotRequireEmployeeProfile() {
        Department department = new Department();
        department.setName("Sales");
        department.setCode("DEPT_SALES");
        department.setLevel("一级部门");
        department.setPermissionDelegationGeneration(13L);
        Employee targetEmployee = employee(UUID.randomUUID(), department);
        targetEmployee.setPermissionDelegationGeneration(12L);
        UserAccount targetAccount = account(UUID.randomUUID(), targetEmployee.getId());
        targetAccount.setPermissionDelegationGeneration(11L);
        UserAccount grantorAccount = account(UUID.randomUUID(), null);
        grantorAccount.setSuperAdmin(true);
        grantorAccount.setPermissionDelegationGeneration(21L);
        grantorAccount.setAuthVersion(22L);
        Permission permission = new Permission();
        permission.setCode(CODE);

        when(employeeRepo.findById(targetEmployee.getId()))
                .thenReturn(Optional.of(targetEmployee));
        when(userAccountRepo.findById(targetAccount.getId()))
                .thenReturn(Optional.of(targetAccount));
        when(userAccountRepo.findById(grantorAccount.getId()))
                .thenReturn(Optional.of(grantorAccount));
        when(departmentPermissionRepo.findPermissionCodesByDepartmentIdsWithAncestors(
                List.of(department.getId()))).thenReturn(List.of());
        when(overrideRepo.findCodeAndEffectByUserId(targetAccount.getId()))
                .thenReturn(List.of());
        when(overrideRepo.findCodeAndEffectByUserId(grantorAccount.getId()))
                .thenReturn(List.of());
        when(permissionRepo.findAllByActiveTrue()).thenReturn(List.of(permission));
        when(managerDelegationRepo.currentAuthorizationEpoch()).thenReturn(24L);

        ManagerPermissionDelegationRepository.EnabledDelegationCandidate candidate =
                mock(ManagerPermissionDelegationRepository.EnabledDelegationCandidate.class);
        when(candidate.getPermissionCode()).thenReturn(CODE);
        when(candidate.getDepartmentId()).thenReturn(department.getId());
        when(candidate.getGrantorUserId()).thenReturn(grantorAccount.getId());
        when(candidate.getSurfaceKey()).thenReturn("sales.order");
        when(candidate.getTargetUserGeneration()).thenReturn(11L);
        when(candidate.getTargetEmployeeGeneration()).thenReturn(12L);
        when(candidate.getTargetDepartmentGeneration()).thenReturn(13L);
        when(candidate.getGrantorUserGeneration()).thenReturn(21L);
        when(candidate.getGrantorAuthVersion()).thenReturn(22L);
        when(candidate.getGrantorAuthorizationEpoch()).thenReturn(24L);
        when(candidate.getScopeSource()).thenReturn("SUPER_ADMIN");
        when(candidate.getGrantorEmployeeGeneration()).thenReturn(null);
        when(candidate.getScopeDepartmentId()).thenReturn(null);
        when(candidate.getScopeGeneration()).thenReturn(null);
        when(candidate.getScopeAssignmentId()).thenReturn(null);
        when(candidate.getScopeAssignmentVersion()).thenReturn(null);
        when(managerDelegationRepo.findEnabledCandidatesByUserId(targetAccount.getId()))
                .thenReturn(List.of(candidate));

        PermissionResolver.PermBreakdown result = resolver.breakdownOf(targetAccount);

        assertTrue(result.managerGrants().contains(CODE));
        assertTrue(result.effective().contains(CODE));
        verify(departmentRepo, never()).findManagerScopeDepartmentId(
                department.getId(), null);
    }

    private Fixture eligibleDelegation() {
        Department department = new Department();
        department.setName("Sales");
        department.setCode("DEPT_SALES");
        department.setLevel("一级部门");
        department.setPermissionDelegationGeneration(13L);

        Employee targetEmployee = employee(UUID.randomUUID(), department);
        targetEmployee.setPermissionDelegationGeneration(12L);
        UserAccount targetAccount = account(UUID.randomUUID(), targetEmployee.getId());
        targetAccount.setPermissionDelegationGeneration(11L);
        Employee grantorEmployee = employee(UUID.randomUUID(), department);
        grantorEmployee.setPermissionDelegationGeneration(23L);
        UserAccount grantorAccount = account(UUID.randomUUID(), grantorEmployee.getId());
        grantorAccount.setPermissionDelegationGeneration(21L);
        grantorAccount.setAuthVersion(22L);

        lenient().when(employeeRepo.findById(targetEmployee.getId()))
                .thenReturn(Optional.of(targetEmployee));
        lenient().when(employeeRepo.findById(grantorEmployee.getId()))
                .thenReturn(Optional.of(grantorEmployee));
        lenient().when(userAccountRepo.findById(targetAccount.getId()))
                .thenReturn(Optional.of(targetAccount));
        lenient().when(userAccountRepo.findById(grantorAccount.getId()))
                .thenReturn(Optional.of(grantorAccount));
        lenient().when(departmentPermissionRepo.findPermissionCodesByDepartmentIdsWithAncestors(
                List.of(department.getId()))).thenReturn(List.of());
        lenient().when(overrideRepo.findCodeAndEffectByUserId(targetAccount.getId()))
                .thenReturn(List.of());
        lenient().when(overrideRepo.findCodeAndEffectByUserId(grantorAccount.getId()))
                .thenReturn(List.<Object[]>of(
                        new Object[]{CODE, "grant", "SUPER_ADMIN_CONFIRMED"}));
        lenient().when(departmentRepo.findById(department.getId()))
                .thenReturn(Optional.of(department));
        lenient().when(departmentRepo.findManagerScopeDepartmentId(
                department.getId(), grantorEmployee.getId()))
                .thenReturn(Optional.of(department.getId()));
        lenient().when(managerDelegationRepo.currentAuthorizationEpoch())
                .thenReturn(24L);

        ManagerPermissionDelegationRepository.EnabledDelegationCandidate candidate =
                mock(ManagerPermissionDelegationRepository.EnabledDelegationCandidate.class);
        lenient().when(candidate.getPermissionCode()).thenReturn(CODE);
        lenient().when(candidate.getDepartmentId()).thenReturn(department.getId());
        lenient().when(candidate.getGrantorUserId()).thenReturn(grantorAccount.getId());
        lenient().when(candidate.getSurfaceKey()).thenReturn("sales.order");
        lenient().when(candidate.getTargetUserGeneration()).thenReturn(11L);
        lenient().when(candidate.getTargetEmployeeGeneration()).thenReturn(12L);
        lenient().when(candidate.getTargetDepartmentGeneration()).thenReturn(13L);
        lenient().when(candidate.getGrantorUserGeneration()).thenReturn(21L);
        lenient().when(candidate.getGrantorEmployeeGeneration()).thenReturn(23L);
        lenient().when(candidate.getGrantorAuthVersion()).thenReturn(22L);
        lenient().when(candidate.getGrantorAuthorizationEpoch()).thenReturn(24L);
        lenient().when(candidate.getScopeSource()).thenReturn("DEPARTMENT_MANAGER");
        lenient().when(candidate.getScopeDepartmentId()).thenReturn(department.getId());
        lenient().when(candidate.getScopeGeneration()).thenReturn(13L);
        lenient().when(candidate.getScopeAssignmentId()).thenReturn(null);
        lenient().when(candidate.getScopeAssignmentVersion()).thenReturn(null);
        lenient().when(managerDelegationRepo.findEnabledCandidatesByUserId(
                targetAccount.getId()))
                .thenReturn(List.of(candidate));

        return new Fixture(
                targetAccount,
                targetEmployee,
                grantorAccount,
                grantorEmployee,
                department,
                candidate);
    }

    private static Employee employee(UUID id, Department department) {
        Employee employee = new Employee();
        employee.setId(id);
        employee.setDepartment(department);
        employee.setStatus("active");
        return employee;
    }

    private static UserAccount account(UUID id, UUID employeeId) {
        UserAccount account = new UserAccount();
        account.setId(id);
        account.setEmployeeId(employeeId);
        account.setLoginAccount("U-" + id);
        account.setStatus("active");
        return account;
    }

    private enum CandidateMismatch {
        TARGET_USER_GENERATION,
        TARGET_EMPLOYEE_GENERATION,
        TARGET_DEPARTMENT_GENERATION,
        TARGET_DEPARTMENT_ID,
        GRANTOR_USER_GENERATION,
        GRANTOR_EMPLOYEE_GENERATION,
        GRANTOR_AUTH_VERSION,
        AUTHORIZATION_EPOCH,
        SCOPE_GENERATION,
        SCOPE_DEPARTMENT_ID,
        LEGACY_SCOPE_SOURCE,
        UNEXPECTED_ASSIGNMENT_SHAPE
    }

    private record Fixture(
            UserAccount targetAccount,
            Employee targetEmployee,
            UserAccount grantorAccount,
            Employee grantorEmployee,
            Department department,
            ManagerPermissionDelegationRepository.EnabledDelegationCandidate candidate) {
    }
}
