package com.uten.imp.features.auth;

import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.PagePermissionDelegationFeatureGate;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistry;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSecondaryDepartmentRepository;
import com.uten.imp.features.rbac.*;
import com.uten.imp.security.PermissionDelegationPolicy;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class PermissionResolverDependencyTest {
    @Test
    void rawConfiguredActionAndUsableAuthorityAreDistinguishedUntilItsReadIsGranted() {
        Fixture fixture = fixture();
        when(fixture.overrides.findCodeAndEffectByUserId(fixture.actor.getId())).thenReturn(
                List.<Object[]>of(new Object[]{"sales_shipment_finance:approve", "grant", "SUPER_ADMIN_CONFIRMED"}));
        var missing = fixture.resolver.breakdownOf(fixture.actor);
        assertThat(missing.grants()).contains("sales_shipment_finance:approve");
        assertThat(missing.configuredPermissions()).containsExactly("sales_shipment_finance:approve");
        assertThat(missing.effective()).doesNotContain("sales_shipment_finance:approve");
        when(fixture.permissions.findBaselineCodes()).thenReturn(List.of("sales_shipment_finance:view"));
        assertThat(fixture.resolver.permsOf(fixture.actor)).containsExactlyInAnyOrder(
                "sales_shipment_finance:approve", "sales_shipment_finance:view");
        verify(fixture.permissions, times(1)).findAll();
    }

    @Test
    void anExplicitReadRevokeAlsoMakesItsConfiguredActionUnusable() {
        Fixture fixture = fixture();
        when(fixture.permissions.findBaselineCodes()).thenReturn(List.of("sales_shipment_finance:view"));
        when(fixture.overrides.findCodeAndEffectByUserId(fixture.actor.getId())).thenReturn(List.of(
                new Object[]{"sales_shipment_finance:approve", "grant", "SUPER_ADMIN_CONFIRMED"},
                new Object[]{"sales_shipment_finance:view", "revoke", "SUPER_ADMIN_CONFIRMED"}));
        var result = fixture.resolver.breakdownOf(fixture.actor);
        assertThat(result.revokes()).containsExactly("sales_shipment_finance:view");
        assertThat(result.grants()).containsExactly("sales_shipment_finance:approve");
        assertThat(result.configuredPermissions()).containsExactly("sales_shipment_finance:approve");
        assertThat(result.effective()).isEmpty();
    }

    @Test
    void configuredSourcesAreCombinedBeforeNormalizationWithoutRestoringAnExplicitRevoke() {
        var state = new PermissionResolver.PermBreakdown(null, null,
                Set.of("department", "revoked"), Set.of("baseline", "revoked"),
                List.of("personal", "revoked"), List.of(), List.of(), List.of(),
                List.of("delegated", "revoked"), true, List.of("revoked"), Set.of("normalized"));
        assertThat(state.configuredPermissions()).containsExactlyInAnyOrder(
                "baseline", "department", "personal", "delegated");
        assertThat(state.effective()).containsExactly("normalized");
    }

    @Test
    void superAdminCatalogAuthorityRemainsConsistentWithTheDependencyView() {
        Fixture fixture = fixture();
        fixture.actor.setSuperAdmin(true);
        when(fixture.permissions.findAllCodes()).thenReturn(List.of(
                "sales_shipment_finance:approve", "sales_shipment_finance:view"));
        assertThat(fixture.resolver.permsOf(fixture.actor)).isEqualTo(fixture.resolver.breakdownOf(fixture.actor).effective());
    }

    @Test
    void independentFieldAndCommandGrantsSurviveExplicitRevokesOfUnrelatedRootReads() {
        List<String> commands = List.of("employee:create", "employee:pii:edit", "employee:compensation:edit",
                "goods:price:edit", "attachment:upload", "attachment:download", "rd_task:resolve",
                "purchase_order:decompose", "subcontract_order:decompose", "account:balance:adjust");
        List<String> reads = List.of("employee:view", "department:view", "goods:view", "attachment:view", "rd_task:view",
                "purchase_order:view", "purchase_request:view", "subcontract_order:view", "subcontract_application:view",
                "account:view", "account:balance:view");
        List<Permission> definitions = new java.util.ArrayList<>();
        commands.forEach(code -> definitions.add(permission(code, "EDIT")));
        reads.forEach(code -> definitions.add(permission(code, "VIEW")));
        Fixture fixture = fixture(definitions);
        when(fixture.permissions.findBaselineCodes()).thenReturn(reads);
        List<Object[]> configured = new java.util.ArrayList<>();
        commands.forEach(code -> configured.add(new Object[]{code, "grant", "SUPER_ADMIN_CONFIRMED"}));
        reads.forEach(code -> configured.add(new Object[]{code, "revoke", "SUPER_ADMIN_CONFIRMED"}));
        when(fixture.overrides.findCodeAndEffectByUserId(fixture.actor.getId())).thenReturn(configured);
        var result = fixture.resolver.breakdownOf(fixture.actor);
        assertThat(result.grants()).containsExactlyInAnyOrderElementsOf(commands);
        assertThat(result.revokes()).containsExactlyInAnyOrderElementsOf(reads);
        assertThat(result.effective()).containsExactlyInAnyOrderElementsOf(commands);
        assertThat(fixture.resolver.permsOf(fixture.actor)).containsExactlyInAnyOrderElementsOf(commands);
    }

    @Test
    void aNavigationGapIsVisibleToGrantPlanningWithoutRemovingIndependentApiAuthority() {
        Permission read = permission("goods:view", "VIEW");
        Permission edit = permission("goods:edit", "EDIT");
        Fixture fixture = fixture(List.of(read, edit));
        when(fixture.overrides.findCodeAndEffectByUserId(fixture.actor.getId())).thenReturn(List.of(
                new Object[]{"goods:edit", "grant", "SUPER_ADMIN_CONFIRMED"},
                new Object[]{"goods:view", "revoke", "SUPER_ADMIN_CONFIRMED"}));
        var result = fixture.resolver.breakdownOf(fixture.actor);
        assertThat(result.effective()).containsExactly("goods:edit");
        assertThat(new PermissionDependencyCatalog(List.of(read, edit))
                .missingDependencies("goods:edit", result.effective())).containsExactly("goods:view");
    }

    private Fixture fixture() {
        return fixture(List.of(permission("sales_shipment_finance:view", "VIEW"),
                permission("sales_shipment_finance:approve", "APPROVE")));
    }

    private Fixture fixture(List<Permission> definitions) {
        PermissionRepository permissions = mock(PermissionRepository.class);
        when(permissions.findAll()).thenReturn(definitions);
        UserPermissionOverrideRepository overrides = mock(UserPermissionOverrideRepository.class);
        UserAccount actor = new UserAccount(); actor.setId(UUID.randomUUID());
        var resolver = new PermissionResolver(permissions, mock(DepartmentPermissionRepository.class), overrides,
                mock(EmployeeRepository.class), mock(EmployeeSecondaryDepartmentRepository.class),
                mock(UserAccountRepository.class), mock(DepartmentRepository.class), mock(ManagerPermissionDelegationRepository.class),
                mock(PermissionDelegationPolicy.class), mock(PermissionSurfaceRegistry.class),
                new PagePermissionDelegationFeatureGate(false));
        resolver.initializeDependencyCatalog();
        return new Fixture(permissions, overrides, actor, resolver);
    }

    private Permission permission(String code, String type) {
        Permission permission = new Permission();
        permission.setCode(code); permission.setActionType(type);
        return permission;
    }

    private record Fixture(PermissionRepository permissions, UserPermissionOverrideRepository overrides,
            UserAccount actor, PermissionResolver resolver) {}
}
