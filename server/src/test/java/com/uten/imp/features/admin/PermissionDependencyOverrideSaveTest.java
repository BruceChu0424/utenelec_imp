package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.dto.PermissionBulkScopeDto;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.rbac.*;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class PermissionDependencyOverrideSaveTest {
    private final UserPermissionOverrideRepository overrides = mock(UserPermissionOverrideRepository.class);
    private final PermissionRepository permissions = mock(PermissionRepository.class);
    private final PermissionResolver resolver = mock(PermissionResolver.class);
    private final AdminUserSupport support = mock(AdminUserSupport.class);
    private final AdminAccountLifecycleLock lifecycle = mock(AdminAccountLifecycleLock.class);
    private final DepartmentPermissionAdminService departments = mock(DepartmentPermissionAdminService.class);
    private final PermissionOverrideAdminService service = new PermissionOverrideAdminService(overrides, permissions,
            mock(TxSessionVars.class), support, mock(RefreshTokenRepository.class), lifecycle, resolver, departments,
            mock(PermissionChangeAudit.class));
    private final UserAccount target = new UserAccount();
    private final Permission action = permission("purchase_order:decompose", "EXECUTE");
    private final Permission orderView = permission("purchase_order:view", "VIEW");
    private final Permission requestView = permission("purchase_request:view", "VIEW");

    private void fixture(Set<String> inherited) {
        target.setId(UUID.randomUUID()); target.setStatus("active");
        when(lifecycle.lock(target.getId())).thenReturn(new AdminAccountLifecycleLock.LockedTarget(new Employee(), target));
        AuthUser actor = mock(AuthUser.class); when(actor.getId()).thenReturn(UUID.randomUUID());
        when(support.requireCurrentUser()).thenReturn(actor);
        when(resolver.breakdownOf(target)).thenReturn(new PermissionResolver.PermBreakdown(null, null,
                inherited, Set.of(), List.of(), List.of(), List.of(), List.of(), List.of(), false, List.of(), inherited));
        List<Permission> catalog = List.of(action, orderView, requestView);
        when(permissions.findAll()).thenReturn(catalog);
        when(permissions.findByCodeIn(anyCollection())).thenAnswer(invocation -> {
            java.util.Collection<String> codes = invocation.getArgument(0);
            return catalog.stream().filter(permission -> codes.contains(permission.getCode())).toList();
        });
    }

    @Test
    void directAndAiSharedSaveAddsOnlyMissingOrdinaryReadsWithoutDuplicatingInheritedReads() {
        fixture(Set.of(orderView.getCode()));
        service.setPermissionOverrides(target.getId(), List.of(action.getCode()), List.of());
        assertThat(savedCodes()).containsExactlyInAnyOrder(action.getCode(), requestView.getCode());
    }

    @Test
    void aNavigationReadExplicitlyRevokedByTheAdministratorIsPreservedWithoutBlockingTheAction() {
        fixture(Set.of(orderView.getCode()));
        service.setPermissionOverrides(target.getId(), List.of(action.getCode()), List.of(requestView.getCode()));
        @SuppressWarnings({"unchecked", "rawtypes"})
        ArgumentCaptor<List<UserPermissionOverride>> saved = ArgumentCaptor.forClass((Class) List.class);
        verify(overrides).saveAllAndFlush(saved.capture());
        assertThat(saved.getValue()).hasSize(2).anySatisfy(row -> {
            assertThat(row.getId().getPermissionId()).isEqualTo(action.getId());
            assertThat(row.getEffect()).isEqualTo("grant");
        }).anySatisfy(row -> {
            assertThat(row.getId().getPermissionId()).isEqualTo(requestView.getId());
            assertThat(row.getEffect()).isEqualTo("revoke");
        });
    }

    @Test
    void personalCategoryBulkAddsNecessaryReadsOutsideTheSelectedCategory() {
        fixture(Set.of());
        var scope = new PermissionBulkScopeDto("采购管理", "采购订货");
        when(departments.bulkCandidates(scope)).thenReturn(List.of(action));
        service.grantAll(target.getId(), scope);
        assertThat(savedCodes()).containsExactlyInAnyOrder(action.getCode(), orderView.getCode(), requestView.getCode());
    }

    @Test
    void personalBulkRepairsAnInheritedActionWithoutDuplicatingItsDepartmentGrant() {
        fixture(Set.of(action.getCode()));
        var scope = new PermissionBulkScopeDto("采购管理", "采购订货");
        when(departments.bulkCandidates(scope)).thenReturn(List.of(action));
        service.grantAll(target.getId(), scope);
        assertThat(savedCodes()).containsExactlyInAnyOrder(orderView.getCode(), requestView.getCode());
    }

    @Test
    void individualOnlyNavigationNeedsAnExplicitGrantWithoutBlockingTheIndependentAction() {
        fixture(Set.of(orderView.getCode()));
        requestView.setGrantPolicy(new String[]{"INDIVIDUAL_ONLY"});
        service.setPermissionOverrides(target.getId(), List.of(action.getCode()), List.of());
        assertThat(savedCodes()).containsExactly(action.getCode());
    }

    @Test
    void anExplicitRevokeOfAHardFinanceReadStillRejectsTheNewAction() {
        action.setCode("sales_order_finance:confirm"); orderView.setCode("sales_order_finance:view");
        fixture(Set.of());
        assertThat(assertThrows(ApiException.class, () -> service.setPermissionOverrides(target.getId(),
                List.of(action.getCode()), List.of(orderView.getCode()))).getMessage()).contains("明确收回");
        verify(overrides, never()).saveAllAndFlush(any());
    }

    @Test
    void aSharedPersonalSaveChoosesTheOtherHardReturnReadInsteadOfBypassingACentralRevoke() {
        action.setCode("procurement_iqc_rejection:record_return");
        orderView.setCode("warehouse_iqc_return:view"); requestView.setCode("procurement_iqc_rejection:view");
        fixture(Set.of());
        service.setPermissionOverrides(target.getId(), List.of(action.getCode()), List.of(orderView.getCode()));
        @SuppressWarnings({"unchecked", "rawtypes"})
        ArgumentCaptor<List<UserPermissionOverride>> saved = ArgumentCaptor.forClass((Class) List.class);
        verify(overrides).saveAllAndFlush(saved.capture());
        assertThat(saved.getValue()).hasSize(3).anySatisfy(row -> {
            assertThat(row.getId().getPermissionId()).isEqualTo(orderView.getId());
            assertThat(row.getEffect()).isEqualTo("revoke");
        }).anySatisfy(row -> {
            assertThat(row.getId().getPermissionId()).isEqualTo(requestView.getId());
            assertThat(row.getEffect()).isEqualTo("grant");
        });
    }

    @Test
    void revokingAReadDoesNotPreventRevocationBecauseAnOldActionGrantStillExists() {
        fixture(Set.of(orderView.getCode(), requestView.getCode()));
        when(overrides.findCodeAndEffectByUserId(target.getId())).thenReturn(java.util.Collections.singletonList(
                new Object[]{action.getCode(), "grant", "SUPER_ADMIN_CONFIRMED"}));
        UserPermissionOverride existing = new UserPermissionOverride();
        existing.setId(new UserPermissionOverrideId(target.getId(), action.getId()));
        existing.setActive(true); existing.setEffect("grant"); existing.setAuthoritySource("SUPER_ADMIN_CONFIRMED");
        existing.setRowVersion(1L);
        when(overrides.findAllByUserIdForUpdate(target.getId())).thenReturn(List.of(existing));
        service.setPermissionOverrides(target.getId(), List.of(action.getCode()), List.of(requestView.getCode()));
        @SuppressWarnings({"unchecked", "rawtypes"})
        ArgumentCaptor<List<UserPermissionOverride>> saved = ArgumentCaptor.forClass((Class) List.class);
        verify(overrides).saveAllAndFlush(saved.capture());
        assertThat(saved.getValue()).hasSize(1).filteredOn(row -> row.getId().getPermissionId().equals(requestView.getId()))
                .allSatisfy(row -> assertThat(row.getEffect()).isEqualTo("revoke"));
        assertThat(existing.isActive()).isTrue();
        assertThat(existing.getRowVersion()).isEqualTo(1L);
        assertThat(saved.getValue()).noneMatch(row -> row.getId().getPermissionId().equals(orderView.getId()));
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private List<String> savedCodes() {
        ArgumentCaptor<List<UserPermissionOverride>> saved = ArgumentCaptor.forClass((Class) List.class);
        verify(overrides).saveAllAndFlush(saved.capture());
        return saved.getValue().stream().map(row -> row.getId().getPermissionId()).map(id ->
                List.of(action, orderView, requestView).stream().filter(permission -> permission.getId().equals(id))
                        .findFirst().orElseThrow().getCode()).toList();
    }

    private static Permission permission(String code, String actionType) {
        Permission permission = new Permission(); permission.setId(UUID.randomUUID());
        permission.setCode(code); permission.setName(code); permission.setActionType(actionType); return permission;
    }
}
