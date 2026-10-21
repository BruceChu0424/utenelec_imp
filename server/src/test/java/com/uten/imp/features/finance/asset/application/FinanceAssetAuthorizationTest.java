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
    void draftDeleteIsIndependentAndRevocationImmediatelyRemovesTheAction() {
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        FinanceAssetAuthorization guard = new FinanceAssetAuthorization(current, new FinanceAssetFeatureGate(true));
        when(current.get()).thenReturn(Optional.of(user(Set.of(FinanceAssetAuthorization.EDIT), false)));
        assertThat(guard.allowedActions("DRAFT", UUID.randomUUID(), false)).containsExactlyInAnyOrder("EDIT", "SUBMIT");
        assertThatThrownBy(() -> guard.require(FinanceAssetAuthorization.DELETE)).isInstanceOf(ApiException.class);
        when(current.get()).thenReturn(Optional.of(user(Set.of(FinanceAssetAuthorization.DELETE), false)));
        assertThat(guard.allowedActions("DRAFT", UUID.randomUUID(), true)).containsExactly("DELETE");
        assertThat(guard.allowedActions("PENDING_APPROVAL", UUID.randomUUID(), true)).doesNotContain("DELETE");
        when(current.get()).thenReturn(Optional.of(user(Set.of(FinanceAssetAuthorization.VIEW), false)));
        assertThat(guard.allowedActions("DRAFT", UUID.randomUUID(), true)).isEmpty();
        when(current.get()).thenReturn(Optional.of(user(Set.of(), true)));
        assertThat(guard.allowedActions("DRAFT", UUID.randomUUID(), false)).contains("DELETE");
    }

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

    @Test
    void postingAndReversalHaveIndependentActionsThroughFinalExecution() {
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        FinanceAssetAuthorization guard = new FinanceAssetAuthorization(current, new FinanceAssetFeatureGate(true));
        AuthUser poster = user(Set.of(FinanceAssetAuthorization.POST), false);
        when(current.get()).thenReturn(Optional.of(poster));
        when(current.id()).thenReturn(Optional.of(poster.getId()));
        UUID maker = UUID.randomUUID();
        assertThat(guard.allowedPostingRunActions("APPROVED", "NORMAL", maker)).containsExactly("POST");
        assertThat(guard.allowedPostingRunActions("APPROVED", "REVERSAL", maker)).isEmpty();
        assertThat(guard.allowedPostingRunActions("POSTED", "NORMAL", maker)).isEmpty();
        assertThatThrownBy(() -> guard.require(FinanceAssetAuthorization.REVERSE)).isInstanceOf(ApiException.class);

        AuthUser reverter = user(Set.of(FinanceAssetAuthorization.REVERSE), false);
        when(current.get()).thenReturn(Optional.of(reverter));
        when(current.id()).thenReturn(Optional.of(reverter.getId()));
        assertThat(guard.allowedPostingRunActions("APPROVED", "NORMAL", maker)).isEmpty();
        assertThat(guard.allowedPostingRunActions("APPROVED", "REVERSAL", maker)).containsExactly("POST");
        assertThat(guard.allowedPostingRunActions("POSTED", "NORMAL", maker)).containsExactly("REVERSE");
        assertThat(guard.allowedPostingRunActions("POSTED", "REVERSAL", maker)).isEmpty();
        assertThat(guard.allowedPostingRunActions("APPROVED", "REVERSAL", reverter.getId())).isEmpty();
        assertThat(guard.allowedPostingRunActions("SUBMITTED", "REVERSAL", maker)).isEmpty();
        assertThatThrownBy(() -> guard.require(FinanceAssetAuthorization.POST)).isInstanceOf(ApiException.class);
    }

    private static AuthUser user(Set<String> permissions, boolean superAdmin) {
        return new AuthUser(
                UUID.randomUUID(), UUID.randomUUID(), "asset-user", permissions,
                false, true, superAdmin);
    }
}
