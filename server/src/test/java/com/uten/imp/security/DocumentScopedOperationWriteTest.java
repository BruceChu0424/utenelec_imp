package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class DocumentScopedOperationWriteTest {

    @Test
    void pooledApproverNeedsNormalReadScopeBeforeAuthorityCanWrite() {
        OwnerVisibility visibility = mock(OwnerVisibility.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        FinanceDocumentAccessPolicy policy = new FinanceDocumentAccessPolicy(
                visibility, currentUser);
        UUID owner = UUID.randomUUID();
        AuthUser approver = new AuthUser(
                UUID.randomUUID(), UUID.randomUUID(), "approver",
                Set.of(), Set.of("finance_receipt:approve"),
                false, true, false);
        when(currentUser.get()).thenReturn(Optional.of(approver));

        when(visibility.evaluate(
                FinanceDocumentAccessPolicy.SCOPE,
                FinanceDocumentAccessPolicy.VIEW_ALL))
                .thenReturn(new OwnerVisibility.OwnerScope(
                        false, Set.of(), Set.of()));
        ApiException hidden = assertThrows(ApiException.class,
                () -> policy.requireScopedOperationWritable(
                        owner, "forbidden", "finance_receipt:approve"));
        assertEquals(ErrorCode.FORBIDDEN, hidden.getCode());

        when(visibility.evaluate(
                FinanceDocumentAccessPolicy.SCOPE,
                FinanceDocumentAccessPolicy.VIEW_ALL))
                .thenReturn(new OwnerVisibility.OwnerScope(
                        false, Set.of(owner), Set.of()));
        assertDoesNotThrow(() -> policy.requireScopedOperationWritable(
                owner, "forbidden", "finance_receipt:approve"));
    }
}
