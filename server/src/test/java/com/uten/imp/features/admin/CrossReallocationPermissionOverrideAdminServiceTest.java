package com.uten.imp.features.admin;

import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.UserPermissionOverride;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class CrossReallocationPermissionOverrideAdminServiceTest {

    private static final String CODE =
            "production_material_analysis:cross_reallocate";

    @Mock
    private UserPermissionOverrideRepository overrideRepo;
    @Mock
    private PermissionRepository permissionRepo;
    @Mock
    private TxSessionVars tx;
    @Mock
    private AdminUserSupport support;
    @Mock
    private RefreshTokenRepository refreshTokenRepo;
    @Mock
    private UserAccountRepository userAccountRepo;

    @ParameterizedTest
    @ValueSource(strings = {"grant", "revoke"})
    void dedicatedPermissionCanBeGrantedOrRevokedAndInvalidatesRefreshTokens(
            String effect) {
        UUID userId = UUID.randomUUID();
        UUID permissionId = UUID.randomUUID();
        UUID actorUserId = UUID.randomUUID();
        UserAccount target = new UserAccount();
        target.setId(userId);
        Permission permission = new Permission();
        permission.setId(permissionId);
        permission.setCode(CODE);
        permission.setName("跨物料分析让料与优先补齐");
        when(userAccountRepo.findByIdForUpdate(userId))
                .thenReturn(java.util.Optional.of(target));
        AuthUser actor = mock(AuthUser.class);
        when(actor.getId()).thenReturn(actorUserId);
        when(support.requireCurrentUser()).thenReturn(actor);
        when(permissionRepo.findByCodeIn(anyCollection()))
                .thenReturn(List.of(permission));
        when(overrideRepo.findAllByUserIdForUpdate(userId))
                .thenReturn(List.of());
        PermissionOverrideAdminService service =
                new PermissionOverrideAdminService(
                        overrideRepo, permissionRepo, tx, support,
                        refreshTokenRepo, userAccountRepo);

        service.setPermissionOverrides(
                userId,
                "grant".equals(effect) ? List.of(CODE) : List.of(),
                "revoke".equals(effect) ? List.of(CODE) : List.of());

        @SuppressWarnings("unchecked")
        ArgumentCaptor<List<UserPermissionOverride>> saved =
                ArgumentCaptor.forClass(List.class);
        verify(overrideRepo).saveAllAndFlush(saved.capture());
        UserPermissionOverride row = saved.getValue().getFirst();
        assertThat(row.getId().getUserId()).isEqualTo(userId);
        assertThat(row.getId().getPermissionId())
                .isEqualTo(permissionId);
        assertThat(row.getEffect()).isEqualTo(effect);
        assertThat(row.isActive()).isTrue();
        assertThat(row.getRowVersion()).isEqualTo(1L);
        assertThat(row.getAuthoritySource())
                .isEqualTo("SUPER_ADMIN_CONFIRMED");
        assertThat(row.getSourceActorUserId())
                .isEqualTo(actorUserId);
        InOrder order = inOrder(
                userAccountRepo, overrideRepo, refreshTokenRepo);
        order.verify(userAccountRepo).findByIdForUpdate(userId);
        order.verify(overrideRepo).findAllByUserIdForUpdate(userId);
        order.verify(overrideRepo).saveAllAndFlush(saved.getValue());
        order.verify(refreshTokenRepo).revokeAllByUserId(userId);
    }

    @Test
    void removingOverrideCreatesNeutralTombstoneAndAdvancesVersion() {
        UUID userId = UUID.randomUUID();
        UUID permissionId = UUID.randomUUID();
        UUID actorUserId = UUID.randomUUID();
        UserAccount target = new UserAccount();
        target.setId(userId);
        UserPermissionOverride existing = new UserPermissionOverride();
        existing.setId(new com.uten.imp.features.rbac.UserPermissionOverrideId(
                userId, permissionId));
        existing.setEffect("grant");
        existing.setActive(true);
        existing.setRowVersion(7L);
        existing.setAuthoritySource("SUPER_ADMIN_CONFIRMED");

        when(userAccountRepo.findByIdForUpdate(userId))
                .thenReturn(java.util.Optional.of(target));
        AuthUser actor = mock(AuthUser.class);
        when(actor.getId()).thenReturn(actorUserId);
        when(support.requireCurrentUser()).thenReturn(actor);
        when(overrideRepo.findAllByUserIdForUpdate(userId))
                .thenReturn(List.of(existing));
        PermissionOverrideAdminService service =
                new PermissionOverrideAdminService(
                        overrideRepo, permissionRepo, tx, support,
                        refreshTokenRepo, userAccountRepo);

        service.setPermissionOverrides(userId, List.of(), List.of());

        assertThat(existing.isActive()).isFalse();
        assertThat(existing.getRowVersion()).isEqualTo(8L);
        assertThat(existing.getSourceActorUserId()).isEqualTo(actorUserId);
        verify(overrideRepo).saveAllAndFlush(List.of(existing));
        verify(refreshTokenRepo).revokeAllByUserId(userId);
    }
}
