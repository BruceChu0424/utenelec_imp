package com.uten.imp.features.finance.asset.application;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class FinanceAssetAttachmentAccessPolicyTest {
    @ParameterizedTest @ValueSource(booleans = {false, true})
    void globalAssetAndFinanceAmountPermissionsAreBothRequired(boolean deferred) {
        var h = new Harness(deferred);
        h.permissions.remove("finance:view:all");
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanView(h.id, h.user()));
        verifyNoInteractions(h.em);
        h.permissions.add("finance:view:all"); h.permissions.remove(FinanceAssetAuthorization.VIEW);
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanView(h.id, h.user()));
        verifyNoInteractions(h.em);
    }

    @ParameterizedTest @ValueSource(booleans = {false, true})
    void readOnlyAuthorityCanViewButCannotChangeFiles(boolean deferred) {
        var h = new Harness(deferred);
        h.permissions.remove(FinanceAssetAuthorization.EDIT);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
        assertFalse(h.sql.getFirst().contains("FOR UPDATE"));
    }

    @ParameterizedTest @ValueSource(booleans = {false, true})
    void originalMissingDeletedRecordCannotBeUsedAsFileOwner(boolean deferred) {
        var h = new Harness(deferred);
        when(h.query.getResultList()).thenReturn(List.of());
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
        denied(ErrorCode.VALIDATION_FAILED, () -> h.policy.requireCanManage(null, h.user()));
        assertTrue(h.sql.stream().allMatch(sql -> sql.contains("WHERE id=:id AND is_deleted=false")));
        verify(h.query, times(2)).setParameter("id", h.id);
    }

    @ParameterizedTest @ValueSource(booleans = {false, true})
    void confirmAndDeleteUseLatestLockedLifecycle(boolean deferred) {
        var h = new Harness(deferred);
        assertDoesNotThrow(() -> h.policy.requireCanManage(h.id, h.user()));
        when(h.query.getResultList()).thenReturn(List.of("PENDING_APPROVAL"));
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
        assertEquals("SELECT lifecycle_status FROM " + (deferred ? "deferred_expenses" : "fixed_assets")
                + " WHERE id=:id AND is_deleted=false FOR UPDATE", h.sql.getLast());
        when(h.query.getResultList()).thenReturn(List.of("DRAFT"));
        assertDoesNotThrow(() -> h.policy.requireCanManageForUpdate(h.id, h.user()));
    }

    @ParameterizedTest @ValueSource(booleans = {false, true})
    void allPostDraftStatesRemainReadableAndImmutable(boolean deferred) {
        var h = new Harness(deferred);
        for (String state : List.of("PENDING_APPROVAL", "APPROVED", "ACTIVE", "DISPOSAL_PENDING",
                "DISPOSED", "TERMINATION_PENDING", "TERMINATED", "COMPLETED", "UNKNOWN")) {
            when(h.query.getResultList()).thenReturn(List.of(state));
            assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
            denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
        }
    }

    private static void denied(ErrorCode expected, org.junit.jupiter.api.function.Executable action) {
        assertEquals(expected, assertThrows(ApiException.class, action).getCode());
    }

    private static class Harness {
        final UUID id = UUID.randomUUID();
        final UUID actor = UUID.randomUUID();
        final EntityManager em = mock(EntityManager.class);
        final Query query = mock(Query.class);
        final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        final Set<String> permissions = new HashSet<>(Set.of(FinanceAssetAuthorization.VIEW,
                FinanceAssetAuthorization.EDIT, "finance:view:all"));
        final List<String> sql = new ArrayList<>();
        final AttachmentOwnerAccessPolicy policy;
        Harness(boolean deferred) {
            when(current.get()).thenAnswer(invocation -> Optional.of(user()));
            when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
                sql.add(invocation.getArgument(0)); return query;
            });
            when(query.setParameter("id", id)).thenReturn(query);
            when(query.getResultList()).thenReturn(List.of("DRAFT"));
            var authorization = new FinanceAssetAuthorization(current, new FinanceAssetFeatureGate(false));
            var prices = new CommercialPriceVisibility(current);
            var configuration = new FinanceAssetAttachmentAccessConfiguration();
            policy = deferred ? configuration.financeDeferredExpenseAttachmentAccessPolicy(em, authorization, prices)
                    : configuration.financeAssetAttachmentAccessPolicy(em, authorization, prices);
            assertEquals(deferred ? "FINANCE_DEFERRED_EXPENSE" : "FINANCE_ASSET", policy.ownerType());
        }
        AuthUser user() { return new AuthUser(actor, actor, "asset", Set.of(), Set.copyOf(permissions), false, true, false); }
    }
}
