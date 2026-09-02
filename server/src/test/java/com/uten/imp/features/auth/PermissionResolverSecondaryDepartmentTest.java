package com.uten.imp.features.auth;

import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.PagePermissionDelegationFeatureGate;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistryTestFixture;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSecondaryDepartmentRepository;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.ManagerPermissionDelegationRepository;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.RolePermissionRepository;
import com.uten.imp.features.rbac.RoleRepository;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.security.PermissionDelegationPolicy;
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
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * V459 兼职部门并入权限合成：
 * 主部门 + 各兼职部门（各含祖先链）取并集；兼职表为空时与既有合成零差异
 * （仍走一次批量 IN 查询）；个人 revoke 恒优先于兼职部门配置。
 */
@ExtendWith(MockitoExtension.class)
class PermissionResolverSecondaryDepartmentTest {

    private static final String PRIMARY_CODE = "sales_order:view";
    private static final String SECONDARY_CODE = "finance_order_approval:review";
    private static final String SECONDARY_REVOKED_CODE = "stock:balance:adjust";

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

    private final UUID userId = UUID.randomUUID();
    private final UUID employeeId = UUID.randomUUID();
    private final UUID primaryDeptId = UUID.randomUUID();
    private final UUID secondaryDeptId = UUID.randomUUID();

    @BeforeEach
    void setUp() {
        resolver = new PermissionResolver(
                userRoleRepo, rolePermissionRepo, permissionRepo, roleRepo,
                departmentPermissionRepo, overrideRepo, employeeRepo,
                secondaryDeptRepo, userAccountRepo, departmentRepo,
                managerDelegationRepo, new PermissionDelegationPolicy(),
                PermissionSurfaceRegistryTestFixture.registry(java.util.Map.of()),
                new PagePermissionDelegationFeatureGate(true));

        when(roleRepo.findByCode("employee")).thenReturn(Optional.empty());
        when(overrideRepo.findCodeAndEffectByUserId(userId)).thenReturn(List.of());
        lenient().when(managerDelegationRepo.findEnabledCandidatesByUserId(userId))
                .thenReturn(List.of());

        Department primary = new Department();
        primary.setId(primaryDeptId);
        primary.setName("综合营销事业部");
        primary.setCode("DEPT_SALES");
        Employee employee = new Employee();
        employee.setId(employeeId);
        employee.setStatus("active");
        employee.setDepartment(primary);
        lenient().when(employeeRepo.findById(employeeId))
                .thenReturn(Optional.of(employee));

        UserAccount account = new UserAccount();
        account.setId(userId);
        account.setEmployeeId(employeeId);
        account.setSuperAdmin(false);
        when(userAccountRepo.findById(userId)).thenReturn(Optional.of(account));
    }

    private void stubDepartments(List<UUID> secondaryDeptIds,
                                 List<String> permissionCodes) {
        when(secondaryDeptRepo.findDepartmentIdsByEmployeeId(employeeId))
                .thenReturn(secondaryDeptIds);
        lenient().when(departmentPermissionRepo
                .findPermissionCodesByDepartmentIdsWithAncestors(
                        secondaryDeptIds.isEmpty()
                                ? List.of(primaryDeptId)
                                : List.of(primaryDeptId, secondaryDeptId)))
                .thenReturn(permissionCodes);
    }

    @Test
    void secondaryDepartmentPermissionsJoinTheEffectiveUnion() {
        stubDepartments(List.of(secondaryDeptId),
                List.of(PRIMARY_CODE, SECONDARY_CODE));

        PermissionResolver.PermBreakdown breakdown =
                resolver.breakdownOf(userAccountRepo.findById(userId).orElseThrow());

        assertTrue(breakdown.effective().contains(PRIMARY_CODE));
        assertTrue(breakdown.effective().contains(SECONDARY_CODE));
        assertTrue(breakdown.departmentPermissions().contains(SECONDARY_CODE));
    }

    @Test
    void withoutSecondaryRowsResolutionMatchesLegacyShape() {
        stubDepartments(List.of(), List.of(PRIMARY_CODE));

        PermissionResolver.PermBreakdown breakdown =
                resolver.breakdownOf(userAccountRepo.findById(userId).orElseThrow());

        assertTrue(breakdown.effective().contains(PRIMARY_CODE));
        assertFalse(breakdown.effective().contains(SECONDARY_CODE));
        // 兼职为空时批量查询只含主部门；旧单部门方法不再被调用。
        verify(departmentPermissionRepo)
                .findPermissionCodesByDepartmentIdsWithAncestors(List.of(primaryDeptId));
        verify(departmentPermissionRepo, never())
                .findPermissionCodesByDepartmentIdWithAncestors(primaryDeptId);
    }

    @Test
    void personalRevokeStillWinsOverSecondaryDepartmentGrant() {
        stubDepartments(List.of(secondaryDeptId),
                List.of(PRIMARY_CODE, SECONDARY_REVOKED_CODE));
        when(overrideRepo.findCodeAndEffectByUserId(userId))
                .thenReturn(List.<Object[]>of(
                        new Object[]{SECONDARY_REVOKED_CODE, "revoke"}));

        PermissionResolver.PermBreakdown breakdown =
                resolver.breakdownOf(userAccountRepo.findById(userId).orElseThrow());

        assertFalse(breakdown.effective().contains(SECONDARY_REVOKED_CODE));
        assertTrue(breakdown.effective().contains(PRIMARY_CODE));
        assertEquals(Set.of(SECONDARY_REVOKED_CODE), Set.copyOf(breakdown.revokes()));
    }

    @Test
    void userWithoutEmployeeSkipsSecondaryLookup() {
        UserAccount account = new UserAccount();
        account.setId(userId);
        account.setEmployeeId(null);
        account.setSuperAdmin(false);
        lenient().when(userAccountRepo.findById(userId))
                .thenReturn(Optional.of(account));

        PermissionResolver.PermBreakdown breakdown =
                resolver.breakdownOf(account);

        assertFalse(breakdown.effective().contains(SECONDARY_CODE));
        verify(secondaryDeptRepo, never()).findDepartmentIdsByEmployeeId(employeeId);
    }
}
