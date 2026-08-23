package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.dto.BatchSetStaffPermissionsRequest;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.ManagerPermissionDelegationRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.UserPermissionOverride;
import com.uten.imp.features.rbac.UserPermissionOverrideId;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.PermissionDelegationPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class PagePermissionWorkspaceServiceTest {

    @Mock private EmployeeRepository employeeRepo;
    @Mock private DepartmentRepository departmentRepo;
    @Mock private DepartmentPermissionStaffQuery staffQuery;
    @Mock private UserAccountRepository userAccountRepo;
    @Mock private PermissionRepository permissionRepo;
    @Mock private ManagerPermissionDelegationRepository delegationRepo;
    @Mock private UserPermissionOverrideRepository overrideRepo;
    @Mock private RefreshTokenRepository refreshTokenRepo;
    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private TxSessionVars tx;
    @Mock private PermissionResolver permissionResolver;
    @Mock private OrganizationPermissionManagementScopeService managementScope;

    private PagePermissionWorkspaceService service;

    @BeforeEach
    void setUp() {
        service = new PagePermissionWorkspaceService(
                employeeRepo,
                departmentRepo,
                staffQuery,
                userAccountRepo,
                permissionRepo,
                delegationRepo,
                overrideRepo,
                refreshTokenRepo,
                currentUser,
                tx,
                permissionResolver,
                new PermissionDelegationPolicy(),
                PermissionSurfaceRegistryTestFixture.registry(Map.of(
                        "basic.goods", Set.of("goods:edit", "goods:export"),
                        "warehouse.stock-balance",
                        Set.of("stock:view", "stock:balance:adjust"))),
                new PagePermissionDelegationFeatureGate(true),
                managementScope);
    }

    @Test
    void ordinaryManagerIsExcludedInsideThePagedSqlQuery() {
        UUID actorUserId = UUID.randomUUID();
        UUID actorEmployeeId = UUID.randomUUID();
        UUID departmentId = UUID.randomUUID();
        UUID targetEmployeeId = UUID.randomUUID();
        AuthUser actor = actor(actorUserId, actorEmployeeId, false);
        Department department = department(departmentId);
        var searchAuthority = new OrganizationPermissionManagementScopeService
                .StaffSearchAuthority(
                        OrganizationPermissionManagementScopeService
                                .StaffSearchScope.MANAGER_SUBTREES,
                        actorEmployeeId);
        UserAccount targetAccount =
                account(UUID.randomUUID(), targetEmployeeId, false);
        when(currentUser.get()).thenReturn(Optional.of(actor));
        when(departmentRepo.findById(departmentId))
                .thenReturn(Optional.of(department));
        when(managementScope.resolveAuthority(actor, departmentId))
                .thenReturn(Optional.of(managerAuthority(department)));
        when(managementScope.staffSearchAuthority(actor))
                .thenReturn(Optional.of(searchAuthority));
        when(staffQuery.query(
                searchAuthority, departmentId, actorEmployeeId,
                "小王", 2, 30))
                .thenReturn(new DepartmentPermissionStaffQuery.Result(
                        List.of(new DepartmentPermissionStaffQuery.StaffProjection(
                                targetEmployeeId,
                                "UT0099",
                                "小王",
                                departmentId,
                                "测试部门",
                                "跟单员",
                                false)),
                        2,
                        30,
                        31,
                        2));
        when(userAccountRepo.findActiveRowsByEmployeeIds(
                List.of(targetEmployeeId)))
                .thenReturn(List.of(targetAccount));

        var result = service.staff(
                "basic.goods", departmentId, "小王", 2, 30);

        assertEquals(31L, result.total());
        assertEquals(1, result.staff().size());
        assertTrue(result.staff().getFirst().accountActive());
        assertEquals(departmentId, result.staff().getFirst().departmentId());
        verify(staffQuery).query(
                searchAuthority, departmentId, actorEmployeeId,
                "小王", 2, 30);
    }

    @Test
    void superAdminSeesEverySurfacePermissionIncludingHighRiskCodes() {
        UUID actorUserId = UUID.randomUUID();
        UUID targetEmployeeId = UUID.randomUUID();
        UUID departmentId = UUID.randomUUID();
        AuthUser actor = actor(actorUserId, null, true);
        Department department = department(departmentId);
        Employee target = employee(targetEmployeeId, department);
        UserAccount actorAccount = account(actorUserId, null, true);
        UserAccount targetAccount =
                account(UUID.randomUUID(), targetEmployeeId, false);
        Permission stockView = permission("stock:view", "查看库存", 1);
        stockView.setActionType("VIEW");
        stockView.setDescription("查看当前库存余额");
        Permission adjust = permission(
                "stock:balance:adjust", "调整库存余额", 2);
        adjust.setActionType("EXECUTE");
        when(currentUser.get()).thenReturn(Optional.of(actor));
        when(departmentRepo.findById(departmentId))
                .thenReturn(Optional.of(department));
        when(managementScope.resolveAuthority(actor, departmentId))
                .thenReturn(Optional.of(superAuthority(actorUserId)));
        when(employeeRepo.findById(targetEmployeeId))
                .thenReturn(Optional.of(target));
        when(userAccountRepo.findById(actorUserId))
                .thenReturn(Optional.of(actorAccount));
        when(userAccountRepo.findByEmployeeId(targetEmployeeId))
                .thenReturn(Optional.of(targetAccount));
        when(delegationRepo.findForEmployeePanel(
                targetAccount.getId(), departmentId))
                .thenReturn(List.of());
        when(overrideRepo.findAllByIdUserId(targetAccount.getId()))
                .thenReturn(List.of());
        when(permissionResolver.breakdownOf(actorAccount))
                .thenReturn(breakdown(Set.of(
                        stockView.getCode(), adjust.getCode())));
        when(permissionResolver.breakdownsOf(targetAccount))
                .thenReturn(new PermissionResolver.PermissionBreakdowns(
                        breakdown(Set.of()), breakdown(Set.of())));
        when(permissionRepo.findByCodeIn(any())).thenReturn(List.of(adjust, stockView));

        var detail = service.employeePermissions(
                targetEmployeeId,
                departmentId,
                "warehouse.stock-balance");

        assertEquals("CENTRAL_OVERRIDE", detail.settingMode());
        assertThat(detail.permissions())
                .extracting(state -> state.code())
                .containsExactly("stock:view", "stock:balance:adjust");
        assertThat(detail.permissions()).allMatch(state -> state.editable());
        assertEquals("VIEW", detail.permissions().getFirst().actionType());
        assertEquals(
                "查看当前库存余额",
                detail.permissions().getFirst().description());
        assertThat(detail.permissions()).allMatch(state -> state.assignable());
    }

    @Test
    void ordinaryManagerSeesEffectiveHighRiskCodeButCannotDelegateIt() {
        UUID actorUserId = UUID.randomUUID();
        UUID actorEmployeeId = UUID.randomUUID();
        UUID targetEmployeeId = UUID.randomUUID();
        UUID departmentId = UUID.randomUUID();
        AuthUser actor = actor(actorUserId, actorEmployeeId, false);
        Department department = department(departmentId);
        Employee target = employee(targetEmployeeId, department);
        UserAccount actorAccount =
                account(actorUserId, actorEmployeeId, false);
        UserAccount targetAccount =
                account(UUID.randomUUID(), targetEmployeeId, false);
        Permission stockView = permission("stock:view", "查看库存", 1);
        Permission adjust = permission(
                "stock:balance:adjust", "调整库存余额", 2);
        when(currentUser.get()).thenReturn(Optional.of(actor));
        when(departmentRepo.findById(departmentId))
                .thenReturn(Optional.of(department));
        when(managementScope.resolveAuthority(actor, departmentId))
                .thenReturn(Optional.of(managerAuthority(department)));
        when(employeeRepo.findById(targetEmployeeId))
                .thenReturn(Optional.of(target));
        when(userAccountRepo.findById(actorUserId))
                .thenReturn(Optional.of(actorAccount));
        when(userAccountRepo.findByEmployeeId(targetEmployeeId))
                .thenReturn(Optional.of(targetAccount));
        when(delegationRepo.findForEmployeePanel(
                targetAccount.getId(), departmentId))
                .thenReturn(List.of());
        when(overrideRepo.findAllByIdUserId(targetAccount.getId()))
                .thenReturn(List.of());
        when(permissionResolver.breakdownOf(actorAccount))
                .thenReturn(breakdown(Set.of(
                        stockView.getCode(), adjust.getCode())));
        when(permissionResolver.delegableCeilingOf(actorAccount))
                .thenReturn(Set.of(stockView.getCode()));
        when(permissionResolver.breakdownsOf(targetAccount))
                .thenReturn(new PermissionResolver.PermissionBreakdowns(
                        breakdown(Set.of()), breakdown(Set.of())));
        when(permissionRepo.findByCodeIn(any())).thenReturn(List.of(adjust, stockView));

        var detail = service.employeePermissions(
                targetEmployeeId,
                departmentId,
                "warehouse.stock-balance");

        assertEquals("MANAGER_DELEGATION", detail.settingMode());
        assertThat(detail.permissions())
                .extracting(state -> state.code())
                .containsExactly("stock:view", "stock:balance:adjust");
        assertThat(detail.permissions().getFirst().editable()).isTrue();
        assertThat(detail.permissions().get(1).editable()).isFalse();
        assertThat(detail.permissions().get(1).reason())
                .contains("高风险");
    }

    @Test
    void superAdminBatchWritesConfirmedOverridesWithCasAndRevokesOnce() {
        UUID actorUserId = UUID.randomUUID();
        UUID targetEmployeeId = UUID.randomUUID();
        UUID targetUserId = UUID.randomUUID();
        UUID departmentId = UUID.randomUUID();
        AuthUser actor = actor(actorUserId, null, true);
        Department department = department(departmentId);
        Employee target = employee(targetEmployeeId, department);
        UserAccount actorAccount = account(actorUserId, null, true);
        UserAccount targetAccount =
                account(targetUserId, targetEmployeeId, false);
        Permission edit = permission("goods:edit", "编辑货品", 1);
        Permission export = permission("goods:export", "导出货品", 2);
        UserPermissionOverride inactiveEdit = new UserPermissionOverride();
        inactiveEdit.setId(new UserPermissionOverrideId(
                targetUserId, edit.getId()));
        inactiveEdit.setEffect("revoke");
        inactiveEdit.setActive(false);
        inactiveEdit.setRowVersion(7L);
        inactiveEdit.setAuthoritySource("SUPER_ADMIN_CONFIRMED");
        when(currentUser.get()).thenReturn(Optional.of(actor));
        when(employeeRepo.findAllByIdForUpdate(any(Collection.class)))
                .thenReturn(List.of(target));
        when(userAccountRepo.findByEmployeeId(targetEmployeeId))
                .thenReturn(Optional.of(targetAccount));
        when(userAccountRepo.findAllByIdForUpdate(any(Collection.class)))
                .thenReturn(List.of(actorAccount, targetAccount));
        when(managementScope.resolveAuthority(actor, departmentId))
                .thenReturn(Optional.of(superAuthority(actorUserId)));
        when(departmentRepo.findAllByIdForUpdate(any(Collection.class)))
                .thenReturn(List.of(department));
        when(delegationRepo.lockAuthorizationEpoch()).thenReturn(7L);
        when(permissionRepo.findByCodeIn(Set.of("goods:edit", "goods:export")))
                .thenReturn(List.of(edit, export));
        when(permissionResolver.breakdownsOf(targetAccount))
                .thenReturn(new PermissionResolver.PermissionBreakdowns(
                        breakdown(Set.of()), breakdown(Set.of())));
        when(overrideRepo.findAllByIdForUpdate(any(Collection.class)))
                .thenReturn(List.of(inactiveEdit));

        var result = service.setPermissions(
                targetEmployeeId,
                departmentId,
                "basic.goods",
                new BatchSetStaffPermissionsRequest(List.of(
                        new BatchSetStaffPermissionsRequest.Change(
                                "goods:export", true, 0L),
                        new BatchSetStaffPermissionsRequest.Change(
                                "goods:edit", true, 7L))));

        assertEquals("CENTRAL_OVERRIDE", result.settingMode());
        assertEquals(2, result.changes().size());
        assertEquals(8L, result.changes().getFirst().rowVersion());
        assertTrue(result.changes().getFirst().effective());
        ArgumentCaptor<List<UserPermissionOverride>> saved =
                ArgumentCaptor.forClass(List.class);
        verify(overrideRepo).saveAllAndFlush(saved.capture());
        assertEquals(2, saved.getValue().size());
        for (UserPermissionOverride row : saved.getValue()) {
            assertEquals("grant", row.getEffect());
            assertEquals("SUPER_ADMIN_CONFIRMED", row.getAuthoritySource());
            assertEquals(actorUserId, row.getSourceActorUserId());
            assertTrue(row.isActive());
        }
        assertEquals(8L, inactiveEdit.getRowVersion());
        verify(refreshTokenRepo).revokeAllByUserId(targetUserId);
    }

    private static PermissionResolver.PermBreakdown breakdown(
            Set<String> effective) {
        return new PermissionResolver.PermBreakdown(
                null,
                null,
                Set.of(),
                Set.of(),
                List.of(),
                List.of(),
                List.of(),
                List.of(),
                List.of(),
                false,
                List.of(),
                effective);
    }

    private static AuthUser actor(
            UUID userId,
            UUID employeeId,
            boolean superAdmin) {
        return new AuthUser(
                userId,
                employeeId,
                "tester",
                Set.of(),
                Set.of(),
                false,
                true,
                superAdmin);
    }

    private static UserAccount account(
            UUID id,
            UUID employeeId,
            boolean superAdmin) {
        UserAccount account = new UserAccount();
        account.setId(id);
        account.setEmployeeId(employeeId);
        account.setStatus("active");
        account.setSuperAdmin(superAdmin);
        account.setDeleted(false);
        return account;
    }

    private static Department department(UUID id) {
        Department department = new Department();
        department.setId(id);
        department.setName("测试部门");
        department.setLevel("一级部门");
        department.setDeleted(false);
        return department;
    }

    private static Employee employee(UUID id, Department department) {
        Employee employee = new Employee();
        employee.setId(id);
        employee.setCode("UT0002");
        employee.setFullName("目标员工");
        employee.setStatus("active");
        employee.setDeleted(false);
        employee.setDepartment(department);
        return employee;
    }

    private static Permission permission(
            String code,
            String name,
            int sortOrder) {
        Permission permission = new Permission();
        permission.setId(UUID.randomUUID());
        permission.setCode(code);
        permission.setName(name);
        permission.setSortOrder(sortOrder);
        return permission;
    }

    private static OrganizationPermissionManagementScopeService.ManagementAuthority
            superAuthority(UUID userId) {
        return new OrganizationPermissionManagementScopeService.ManagementAuthority(
                OrganizationPermissionManagementScopeService.AuthoritySource
                        .SUPER_ADMIN,
                userId,
                0L,
                null,
                null,
                OrganizationPermissionManagementScopeService.AuthorityScope
                        .COMPANY);
    }

    private static OrganizationPermissionManagementScopeService.ManagementAuthority
            managerAuthority(Department department) {
        return new OrganizationPermissionManagementScopeService.ManagementAuthority(
                OrganizationPermissionManagementScopeService.AuthoritySource
                        .DEPARTMENT_MANAGER,
                department.getId(),
                department.getPermissionDelegationGeneration(),
                department.getId(),
                department.getPermissionDelegationGeneration(),
                OrganizationPermissionManagementScopeService.AuthorityScope.SUBTREE);
    }
}
