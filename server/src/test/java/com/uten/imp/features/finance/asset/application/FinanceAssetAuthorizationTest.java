package com.uten.imp.features.finance.asset.application;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class FinanceAssetAuthorizationTest {

    @Test
    void serviceGuardRejectsMissingPermission() {
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(user(Set.of(FinanceAssetAuthorization.VIEW), false)));
        FinanceAssetAuthorization guard = new FinanceAssetAuthorization(current, new FinanceAssetFeatureGate(true));

        assertThatThrownBy(() -> guard.require(FinanceAssetAuthorization.POST))
                .isInstanceOfSatisfying(ApiException.class,
                        exception -> assertThat(exception.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
    }

    @Test
    void makerCannotApproveTheirOwnDraft() {
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        AuthUser actor = user(Set.of(FinanceAssetAuthorization.APPROVE), false);
        when(current.get()).thenReturn(Optional.of(actor));
        when(current.id()).thenReturn(Optional.of(actor.getId()));
        FinanceAssetAuthorization guard = new FinanceAssetAuthorization(current, new FinanceAssetFeatureGate(true));

        assertThat(guard.allowedActions("PENDING_APPROVAL", actor.getId(), false)).isEmpty();
    }

    @Test
    void superAdminStillPassesServiceLayerGuard() {
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(user(Set.of(), true)));

        assertThat(new FinanceAssetAuthorization(current, new FinanceAssetFeatureGate(true))
                .require(FinanceAssetAuthorization.PERIOD_MANAGE))
                .isNotNull();
    }

    @Test
    void disabledPostedWorkflowGateHidesIrreversibleActions() {
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        AuthUser actor = user(Set.of(
                FinanceAssetAuthorization.POST,
                FinanceAssetAuthorization.DISPOSE), false);
        when(current.get()).thenReturn(Optional.of(actor));
        when(current.id()).thenReturn(Optional.of(actor.getId()));
        FinanceAssetAuthorization guard = new FinanceAssetAuthorization(
                current, new FinanceAssetFeatureGate(false));

        assertThat(guard.allowedActions("APPROVED", UUID.randomUUID(), false)).isEmpty();
        assertThat(guard.allowedActions("ACTIVE", UUID.randomUUID(), true)).isEmpty();
    }

    private static AuthUser user(Set<String> permissions, boolean superAdmin) {
        return new AuthUser(
                UUID.randomUUID(), UUID.randomUUID(), "asset-user", Set.of(), permissions,
                false, true, superAdmin);
    }
}
