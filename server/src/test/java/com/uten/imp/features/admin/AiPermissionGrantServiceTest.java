package com.uten.imp.features.admin;

import com.uten.imp.application.port.AiChatActionProposalPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.dto.PermissionOverridesDto;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.RequiresStepUp;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

class AiPermissionGrantServiceTest {
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
    private final UserAccountRepository accounts = mock(UserAccountRepository.class);
    private final PermissionRepository permissions = mock(PermissionRepository.class);
    private final AdminAccountLifecycleLock lifecycle = mock(AdminAccountLifecycleLock.class);
    private final AdminUserSupport support = mock(AdminUserSupport.class);
    private final PermissionOverrideAdminService overrides = mock(PermissionOverrideAdminService.class);
    private final AiChatActionProposalPort proposals = mock(AiChatActionProposalPort.class);
    private final UUID actorId = UUID.randomUUID(), targetId = UUID.randomUUID(), permissionId = UUID.randomUUID();
    private final UUID proposalId = UUID.randomUUID();
    private final AiPermissionGrantService service = new AiPermissionGrantService(current, access, accounts,
            permissions, lifecycle, support, overrides, proposals);
    private UserAccount target;

    @BeforeEach void setUp() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(actorId, UUID.randomUUID(), "admin",
                Set.of("authorization:manage", "ai:use"), false, true, true)));
        when(proposals.consumeServerAction(proposalId, AiChatActionProposalPort.PERMISSION_GRANT)).thenReturn(
                new AiChatActionProposalPort.Consumed(proposalId, AiChatActionProposalPort.PERMISSION_GRANT, targetId.toString(),
                        12L, Map.of("permissionId", permissionId.toString(), "permissionCode", "goods:view")));
        target = new UserAccount(); target.setId(targetId); target.setAuthVersion(12);
        var employee = new Employee(); employee.setFullName("测试员工"); employee.setCode("E-1");
        when(lifecycle.lock(targetId)).thenReturn(new AdminAccountLifecycleLock.LockedTarget(employee, target));
        var actor = new UserAccount(); actor.setId(actorId); actor.setAuthVersion(7); actor.setSuperAdmin(true);
        when(accounts.findByIdForUpdate(actorId)).thenReturn(Optional.of(actor));
        var state = mock(UserAccountRepository.AccountState.class);
        when(state.getAuthorizationEpoch()).thenReturn(4L);
        when(accounts.findAccountStateById(actorId)).thenReturn(Optional.of(state));
        var permission = new Permission(); permission.setId(permissionId); permission.setCode("goods:view"); permission.setName("查看货品");
        when(permissions.findByCode("goods:view")).thenReturn(Optional.of(permission));
        when(overrides.getPermissionOverrides(targetId)).thenReturn(new PermissionOverridesDto(
                List.of("sales_order:view"), List.of("goods:view", "sales_order:edit")));
    }
    @Test void mergesOnlyExplicitPermissionAndPreservesOtherOverrides() {
        assertThat(service.confirm(proposalId).get("status")).isEqualTo("GRANTED");
        verify(overrides).setPermissionOverrides(targetId, List.of("sales_order:view", "goods:view"), List.of("sales_order:edit"));
        verify(proposals).completeServerAction(eq(proposalId), contains("测试员工"));
    }
    @Test void targetVersionChangeRejectsStaleGrantInsteadOfOverwriting() {
        target.setAuthVersion(13);
        assertThatThrownBy(() -> service.confirm(proposalId)).isInstanceOf(ApiException.class);
        verify(overrides, never()).setPermissionOverrides(any(), any(), any());
    }
    @Test void actorDowngradeAfterPreviewRejectsConfirmation() {
        var downgraded = new UserAccount(); downgraded.setId(actorId); downgraded.setAuthVersion(7); downgraded.setSuperAdmin(false);
        when(accounts.findByIdForUpdate(actorId)).thenReturn(Optional.of(downgraded));
        assertThatThrownBy(() -> service.confirm(proposalId)).isInstanceOf(ApiException.class);
        verify(overrides, never()).setPermissionOverrides(any(), any(), any());
    }
    @Test void permissionCatalogCannotTurnPreviewIntoSuperAdminGrant() {
        var protectedPermission = new Permission(); protectedPermission.setId(permissionId);
        protectedPermission.setCode("goods:view"); protectedPermission.setGrantPolicy(new String[]{"SUPERADMIN_ONLY"});
        when(permissions.findByCode("goods:view")).thenReturn(Optional.of(protectedPermission));
        assertThatThrownBy(() -> service.confirm(proposalId)).isInstanceOf(ApiException.class);
        verify(overrides, never()).setPermissionOverrides(any(), any(), any());
    }
    @Test void existingGrantIsIdempotentWithoutASecondWrite() {
        target.setAuthVersion(13);
        when(overrides.getPermissionOverrides(targetId)).thenReturn(new PermissionOverridesDto(List.of("goods:view"), List.of()));
        assertThat(service.confirm(proposalId).get("status")).isEqualTo("ALREADY_GRANTED");
        verify(overrides, never()).setPermissionOverrides(any(), any(), any());
        verify(proposals).completeServerAction(eq(proposalId), anyString());
    }
    @Test void foreignExpiredOrReusedProposalNeverReachesTheGrant() {
        for (var rejection : List.of(new ApiException(ErrorCode.NOT_FOUND),
                new ApiException(ErrorCode.CONFLICT, "expired"), new ApiException(ErrorCode.CONFLICT, "handled"))) {
            doThrow(rejection).when(proposals).consumeServerAction(proposalId, AiChatActionProposalPort.PERMISSION_GRANT);
            assertThatThrownBy(() -> service.confirm(proposalId)).isSameAs(rejection);
        }
        verify(lifecycle, never()).lock(any());
        verify(overrides, never()).setPermissionOverrides(any(), any(), any());
    }
    @Test void ordinaryStaffCannotGrantEvenWithStrayAuthorizationPermission() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(actorId, UUID.randomUUID(), "staff",
                Set.of("authorization:manage", "ai:use"), false, true, false)));
        assertThatThrownBy(() -> service.confirm(proposalId)).isInstanceOf(ApiException.class);
        verifyNoInteractions(proposals);
    }
    @Test void confirmEndpointRequiresExistingStepUpMechanism() throws Exception {
        assertThat(AiPermissionGrantController.class.getMethod("confirm", AiPermissionGrantController.ConfirmRequest.class)
                .isAnnotationPresent(RequiresStepUp.class)).isTrue();
    }
}
