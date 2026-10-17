package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.PermissionChangeAudit;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.StepUpService;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.dto.BatchSetStaffPermissionsRequest;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.*;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.PermissionDelegationPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class PagePermissionDependencySaveTest {
    @Test void managerDerivedReadsUseTheirRealPageSurfaceAndPreserveIndependentSourceRows() {
        Fixture fixture = new Fixture(false, Set.of("goods:create", "goods:view", "material_category:view"), Set.of(), GrantPolicy.NORMAL);
        fixture.save();
        @SuppressWarnings({"unchecked", "rawtypes"})
        ArgumentCaptor<List<ManagerPermissionDelegation>> saved = ArgumentCaptor.forClass((Class) List.class);
        verify(fixture.delegations).saveAllAndFlush(saved.capture());
        assertThat(saved.getValue()).hasSize(3);
        assertThat(saved.getValue()).filteredOn(row -> row.getId().getPermissionId().equals(fixture.category.getId()))
                .allSatisfy(row -> assertThat(row.getSurfaceKey()).isEqualTo("basic.material-category"));
        assertThat(saved.getValue()).filteredOn(row -> row.getId().getPermissionId().equals(fixture.action.getId()))
                .allSatisfy(row -> assertThat(row.getSurfaceKey()).isEqualTo("basic.goods"));
        verifyNoInteractions(fixture.overrides);
    }

    @Test void centralPageSaveCompletesDependenciesThroughTheSameConfirmedOverrideSource() {
        Fixture fixture = new Fixture(true, Set.of(), Set.of(), GrantPolicy.NORMAL);
        fixture.save();
        @SuppressWarnings({"unchecked", "rawtypes"})
        ArgumentCaptor<List<UserPermissionOverride>> saved = ArgumentCaptor.forClass((Class) List.class);
        verify(fixture.overrides).saveAllAndFlush(saved.capture());
        assertThat(saved.getValue()).hasSize(3).allSatisfy(row -> {
            assertThat(row.getEffect()).isEqualTo("grant");
            assertThat(row.getAuthoritySource()).isEqualTo("SUPER_ADMIN_CONFIRMED");
        });
        verify(fixture.delegations, never()).saveAllAndFlush(any());
    }

    @Test void managerCanGrantAnIndependentActionWithoutItsNavigationReadOutsideTheirCeiling() {
        Fixture fixture = new Fixture(false, Set.of("goods:create", "goods:view"), Set.of(), GrantPolicy.NORMAL);
        fixture.save();
        assertThat(savedDelegations(fixture)).hasSize(2)
                .noneMatch(row -> row.getId().getPermissionId().equals(fixture.category.getId()));
    }

    @Test void centralRevokeOnANavigationReadIsPreservedWithoutBlockingAnIndependentAction() {
        Fixture fixture = new Fixture(false, Set.of("goods:create", "goods:view", "material_category:view"),
                Set.of("material_category:view"), GrantPolicy.NORMAL);
        fixture.save();
        assertThat(savedDelegations(fixture)).hasSize(2)
                .noneMatch(row -> row.getId().getPermissionId().equals(fixture.category.getId()));
    }

    @Test void nonDelegableNavigationReadIsNotPromotedOrUsedToBlockAnIndependentAction() {
        Fixture fixture = new Fixture(false, Set.of("goods:create", "goods:view", "material_category:view"),
                Set.of(), GrantPolicy.NON_DELEGABLE);
        fixture.save();
        assertThat(savedDelegations(fixture)).hasSize(2)
                .noneMatch(row -> row.getId().getPermissionId().equals(fixture.category.getId()));
    }

    @Test void managerStillCannotGrantAFinanceActionWhoseHardReadIsOutsideTheirCeiling() {
        Fixture fixture = new Fixture(false, Set.of("sales_shipment_finance:approve"), Set.of(),
                GrantPolicy.NORMAL, "sales_shipment_finance:approve");
        assertThat(assertThrows(ApiException.class, fixture::save).getMessage()).contains("sales_shipment_finance:view");
        verify(fixture.delegations, never()).saveAllAndFlush(any());
    }

    @Test void anExplicitCentralRevokeOfAHardFinanceReadStillBlocksANewAction() {
        Fixture fixture = new Fixture(true, Set.of(), Set.of("sales_shipment_finance:view"),
                GrantPolicy.NORMAL, "sales_shipment_finance:approve");
        assertThat(assertThrows(ApiException.class, fixture::save).getMessage()).contains("明确收回");
        verify(fixture.overrides, never()).saveAllAndFlush(any());
    }

    @Test void aReadRevocationPatchDoesNotRegrantReadsForAnUnchangedConfiguredAction() {
        Fixture fixture = new Fixture(true, Set.of(), Set.of(), GrantPolicy.NORMAL);
        Set<String> configured = Set.of(fixture.action.getCode(), fixture.view.getCode(), fixture.category.getCode());
        var state = new PermissionResolver.PermBreakdown(null, null, configured, Set.of(), List.of(), List.of(),
                List.of(), List.of(), List.of(), false, List.of(), configured);
        when(fixture.resolver.breakdownsOf(fixture.target)).thenReturn(new PermissionResolver.PermissionBreakdowns(state, state));
        fixture.service.setPermissions(fixture.employeeId, fixture.departmentId, "basic.goods",
                new BatchSetStaffPermissionsRequest(List.of(new BatchSetStaffPermissionsRequest.Change(fixture.view.getCode(), false, 0L))));
        @SuppressWarnings({"unchecked", "rawtypes"})
        ArgumentCaptor<List<UserPermissionOverride>> saved = ArgumentCaptor.forClass((Class) List.class);
        verify(fixture.overrides).saveAllAndFlush(saved.capture());
        assertThat(saved.getValue()).hasSize(1).allSatisfy(row -> {
            assertThat(row.getId().getPermissionId()).isEqualTo(fixture.view.getId());
            assertThat(row.getEffect()).isEqualTo("revoke");
        });
        assertThat(state.departmentPermissions()).contains(fixture.action.getCode());
    }

    @Test void globalGoodsEditingDoesNotGrantOrDependOnTheSeparatelyRevokedCategoryTree() {
        Fixture fixture = new Fixture(false, Set.of("goods:edit", "goods:view"), Set.of("material_category:view"),
                GrantPolicy.NORMAL, "goods:edit");
        fixture.save();
        @SuppressWarnings({"unchecked", "rawtypes"})
        ArgumentCaptor<List<ManagerPermissionDelegation>> saved = ArgumentCaptor.forClass((Class) List.class);
        verify(fixture.delegations).saveAllAndFlush(saved.capture());
        assertThat(saved.getValue()).hasSize(2).noneMatch(row -> row.getId().getPermissionId().equals(fixture.category.getId()));
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private List<ManagerPermissionDelegation> savedDelegations(Fixture fixture) {
        ArgumentCaptor<List<ManagerPermissionDelegation>> saved = ArgumentCaptor.forClass((Class) List.class);
        verify(fixture.delegations).saveAllAndFlush(saved.capture());
        return saved.getValue();
    }

    private static final class Fixture {
        final ManagerPermissionDelegationRepository delegations = mock(ManagerPermissionDelegationRepository.class);
        final UserPermissionOverrideRepository overrides = mock(UserPermissionOverrideRepository.class);
        final Permission action;
        final Permission view;
        final Permission category = permission("material_category:view", "VIEW");
        final UUID departmentId = UUID.randomUUID(), employeeId = UUID.randomUUID();
        final PagePermissionWorkspaceService service;
        final PermissionResolver resolver = mock(PermissionResolver.class);
        final UserAccount target;

        Fixture(boolean central, Set<String> ceiling, Set<String> revoked, GrantPolicy categoryPolicy) {
            this(central, ceiling, revoked, categoryPolicy, "goods:create");
        }

        Fixture(boolean central, Set<String> ceiling, Set<String> revoked, GrantPolicy categoryPolicy, String actionCode) {
            action = permission(actionCode, "goods:create".equals(actionCode) ? "CREATE" : "EDIT");
            view = permission(actionCode.startsWith("sales_shipment_finance:")
                    ? "sales_shipment_finance:view" : "goods:view", "VIEW");
            var employees = mock(EmployeeRepository.class); var departments = mock(DepartmentRepository.class);
            var accounts = mock(UserAccountRepository.class); var permissions = mock(PermissionRepository.class);
            var current = mock(SecurityContextCurrentUser.class);
            var scope = mock(OrganizationPermissionManagementScopeService.class);
            UUID actorId = UUID.randomUUID(), actorEmployeeId = UUID.randomUUID(), targetId = UUID.randomUUID();
            AuthUser actor = new AuthUser(actorId, actorEmployeeId, "manager", Set.of(), false, true, central);
            Department department = new Department(); department.setId(departmentId); department.setLevel("一级部门");
            Employee employee = employee(employeeId, department), actorEmployee = employee(actorEmployeeId, department);
            target = account(targetId, employeeId, false);
            UserAccount administrator = account(actorId, actorEmployeeId, central);
            category.setGrantPolicy(new String[]{categoryPolicy.name()});
            var registry = PermissionSurfaceRegistryTestFixture.registry(Map.of(
                    "basic.goods", Set.of(action.getCode(), view.getCode()),
                    "basic.material-category", Set.of(category.getCode())));
            service = new PagePermissionWorkspaceService(employees, departments, mock(DepartmentPermissionStaffQuery.class),
                    accounts, permissions, delegations, overrides, mock(RefreshTokenRepository.class), current,
                    mock(TxSessionVars.class), resolver, new PermissionDelegationPolicy(PermissionGrantPolicyCatalog.fixed(Map.of(
                            action.getCode(), Set.of(GrantPolicy.NORMAL), view.getCode(), Set.of(GrantPolicy.NORMAL),
                            category.getCode(), Set.of(categoryPolicy)))), registry, new PagePermissionDelegationFeatureGate(true),
                    scope, mock(PermissionChangeAudit.class), mock(StepUpService.class));
            when(current.get()).thenReturn(Optional.of(actor));
            when(employees.findAllByIdForUpdate(anyCollection())).thenReturn(List.of(employee, actorEmployee));
            when(accounts.findByEmployeeId(employeeId)).thenReturn(Optional.of(target));
            when(accounts.findAllByIdForUpdate(anyCollection())).thenReturn(List.of(administrator, target));
            when(departments.findAllByIdForUpdate(anyCollection())).thenReturn(List.of(department));
            when(scope.resolveAuthority(actor, departmentId)).thenReturn(Optional.of(new OrganizationPermissionManagementScopeService.ManagementAuthority(
                    central ? OrganizationPermissionManagementScopeService.AuthoritySource.SUPER_ADMIN
                            : OrganizationPermissionManagementScopeService.AuthoritySource.DEPARTMENT_MANAGER,
                    departmentId, 0L, central ? null : departmentId, central ? null : 0L,
                    central ? OrganizationPermissionManagementScopeService.AuthorityScope.COMPANY
                            : OrganizationPermissionManagementScopeService.AuthorityScope.SUBTREE)));
            when(resolver.delegableCeilingOf(administrator)).thenReturn(ceiling);
            var state = new PermissionResolver.PermBreakdown(null, null, Set.of(), Set.of(), List.of(), List.of(),
                    List.of(), List.of(), List.of(), false, revoked.stream().toList(), Set.of());
            when(resolver.breakdownsOf(target)).thenReturn(new PermissionResolver.PermissionBreakdowns(state, state));
            when(resolver.breakdownOf(target)).thenReturn(state);
            List<Permission> catalog = List.of(action, view, category);
            when(permissions.findAll()).thenReturn(catalog);
            when(permissions.findByCodeIn(anyCollection())).thenAnswer(invocation -> {
                java.util.Collection<String> codes = invocation.getArgument(0);
                return catalog.stream().filter(permission -> codes.contains(permission.getCode())).toList();
            });
        }

        void save() {
            service.setPermissions(employeeId, departmentId, "basic.goods", new BatchSetStaffPermissionsRequest(List.of(
                    new BatchSetStaffPermissionsRequest.Change(action.getCode(), true, 0L))));
        }
    }

    private static Permission permission(String code, String kind) {
        Permission permission = new Permission(); permission.setId(UUID.randomUUID()); permission.setCode(code);
        permission.setName(code); permission.setActionType(kind); return permission;
    }
    private static Employee employee(UUID id, Department department) {
        Employee employee = new Employee(); employee.setId(id); employee.setStatus("active"); employee.setDepartment(department); return employee;
    }
    private static UserAccount account(UUID id, UUID employee, boolean admin) {
        UserAccount account = new UserAccount(); account.setId(id); account.setEmployeeId(employee);
        account.setStatus("active"); account.setSuperAdmin(admin); return account;
    }
}
