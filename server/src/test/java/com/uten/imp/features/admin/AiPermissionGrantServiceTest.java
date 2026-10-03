package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
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
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class AiPermissionGrantServiceTest {
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
    private final UserAccountRepository accounts = mock(UserAccountRepository.class);
    private final PermissionRepository permissions = mock(PermissionRepository.class);
    private final AdminAccountLifecycleLock lifecycle = mock(AdminAccountLifecycleLock.class);
    private final AdminUserSupport support = mock(AdminUserSupport.class);
    private final PermissionOverrideAdminService overrides = mock(PermissionOverrideAdminService.class);
    private final AiPermissionProposalCodec codec = mock(AiPermissionProposalCodec.class);
    private final UUID actorId = UUID.randomUUID(), targetId = UUID.randomUUID(), permissionId = UUID.randomUUID();
    private final AiPermissionGrantService service = new AiPermissionGrantService(current, access, accounts,
            permissions, lifecycle, support, overrides, codec);
    private UserAccount target;

    @BeforeEach void setUp() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(actorId, UUID.randomUUID(), "admin",
                Set.of("authorization:manage", "ai:use"), false, true, true)));
        when(codec.decode("signed")).thenReturn(new AiPermissionProposalCodec.Proposal(actorId, 7, 4,
                targetId, 12, permissionId, "goods:view", 1, 2));
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
        assertThat(service.confirm("signed").get("status")).isEqualTo("GRANTED");
        verify(overrides).setPermissionOverrides(targetId, List.of("sales_order:view", "goods:view"), List.of("sales_order:edit"));
    }
    @Test void targetVersionChangeRejectsStaleGrantInsteadOfOverwriting() {
        target.setAuthVersion(13);
        assertThatThrownBy(() -> service.confirm("signed")).isInstanceOf(ApiException.class);
        verify(overrides, never()).setPermissionOverrides(any(), any(), any());
    }
    @Test void actorDowngradeAfterPreviewRejectsConfirmation() {
        var downgraded = new UserAccount(); downgraded.setId(actorId); downgraded.setAuthVersion(8);
        when(accounts.findByIdForUpdate(actorId)).thenReturn(Optional.of(downgraded));
        assertThatThrownBy(() -> service.confirm("signed")).isInstanceOf(ApiException.class);
        verify(overrides, never()).setPermissionOverrides(any(), any(), any());
    }
    @Test void permissionCatalogCannotTurnPreviewIntoSuperAdminGrant() {
        var protectedPermission = new Permission(); protectedPermission.setId(permissionId);
        protectedPermission.setCode("goods:view"); protectedPermission.setGrantPolicy(new String[]{"SUPERADMIN_ONLY"});
        when(permissions.findByCode("goods:view")).thenReturn(Optional.of(protectedPermission));
        assertThatThrownBy(() -> service.confirm("signed")).isInstanceOf(ApiException.class);
        verify(overrides, never()).setPermissionOverrides(any(), any(), any());
    }
    @Test void existingGrantIsIdempotentWithoutASecondWrite() {
        target.setAuthVersion(13);
        when(overrides.getPermissionOverrides(targetId)).thenReturn(new PermissionOverridesDto(List.of("goods:view"), List.of()));
        assertThat(service.confirm("signed").get("status")).isEqualTo("ALREADY_GRANTED");
        verify(overrides, never()).setPermissionOverrides(any(), any(), any());
    }
    @Test void anotherActorCannotConsumeProposal() {
        when(codec.decode("signed")).thenReturn(new AiPermissionProposalCodec.Proposal(UUID.randomUUID(), 7, 4,
                targetId, 12, permissionId, "goods:view", 1, 2));
        assertThatThrownBy(() -> service.confirm("signed")).isInstanceOf(ApiException.class);
        verify(lifecycle, never()).lock(any());
    }
    @Test void ordinaryStaffCannotGrantEvenWithStrayAuthorizationPermission() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(actorId, UUID.randomUUID(), "staff",
                Set.of("authorization:manage", "ai:use"), false, true, false)));
        assertThatThrownBy(() -> service.confirm("signed")).isInstanceOf(ApiException.class);
        verifyNoInteractions(codec);
    }
    @Test void confirmEndpointRequiresExistingStepUpMechanism() throws Exception {
        assertThat(AiPermissionGrantController.class.getMethod("confirm", AiPermissionGrantController.ConfirmRequest.class)
                .isAnnotationPresent(RequiresStepUp.class)).isTrue();
    }
}
