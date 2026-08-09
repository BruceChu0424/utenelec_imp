package com.uten.imp.features.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class FinanceDocumentAccessPolicyTest {

    private final OwnerVisibility ownerVisibility = mock(OwnerVisibility.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
    private final FinanceDocumentAccessPolicy policy =
            new FinanceDocumentAccessPolicy(ownerVisibility, currentUser);

    @BeforeEach
    void ordinaryUser() {
        when(currentUser.get()).thenReturn(Optional.empty());
    }

    @Test
    void evaluatesTheFinanceScopeAndViewAllAuthority() {
        OwnerVisibility.OwnerScope expected =
                new OwnerVisibility.OwnerScope(false, Set.of(UUID.randomUUID()));
        when(ownerVisibility.evaluate(
                FinanceDocumentAccessPolicy.SCOPE,
                FinanceDocumentAccessPolicy.VIEW_ALL))
                .thenReturn(expected);

        assertEquals(expected, policy.scope());
        verify(ownerVisibility).evaluate("finance", "finance:view:all");
    }

    @Test
    void inaccessibleDocumentIsHiddenForReadAndDeniedForWrite() {
        UUID delegatedOwner = UUID.randomUUID();
        UUID otherOwner = UUID.randomUUID();
        scope(false, Set.of(delegatedOwner));

        ApiException hidden = assertThrows(ApiException.class,
                () -> policy.requireReadable(otherOwner, "missing"));
        ApiException denied = assertThrows(ApiException.class,
                () -> policy.requireWritable(otherOwner, "denied"));

        assertEquals(ErrorCode.NOT_FOUND, hidden.getCode());
        assertEquals(ErrorCode.FORBIDDEN, denied.getCode());
    }

    @Test
    void delegatedOwnerIsReadableAndWritable() {
        UUID delegatedOwner = UUID.randomUUID();
        scope(false, Set.of(delegatedOwner));

        assertTrue(policy.canRead(delegatedOwner));
        assertTrue(policy.canWrite(delegatedOwner));
        assertDoesNotThrow(() -> policy.requireWritable(delegatedOwner, "denied"));
    }

    @Test
    void legacyOwnerlessDocumentIsReadOnlyWithoutGlobalAccess() {
        scope(false, Set.of());

        assertTrue(policy.canRead(null));
        assertFalse(policy.canWrite(null));
    }

    private void scope(boolean seeAll, Set<UUID> owners) {
        when(ownerVisibility.evaluate(
                FinanceDocumentAccessPolicy.SCOPE,
                FinanceDocumentAccessPolicy.VIEW_ALL))
                .thenReturn(new OwnerVisibility.OwnerScope(seeAll, owners));
    }
}
