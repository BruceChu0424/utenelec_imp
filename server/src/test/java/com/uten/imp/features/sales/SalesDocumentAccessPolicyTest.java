package com.uten.imp.features.sales;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.Query;
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

class SalesDocumentAccessPolicyTest {

    private final OwnerVisibility ownerVisibility = mock(OwnerVisibility.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
    private final SalesDocumentAccessPolicy policy =
            new SalesDocumentAccessPolicy(ownerVisibility, currentUser);

    @BeforeEach
    void ordinaryUser() {
        when(currentUser.get()).thenReturn(Optional.empty());
    }

    @Test
    void legacyOwnerlessDocumentIsReadableButNotWritable() {
        scope(false, Set.of());

        assertTrue(policy.canRead(null));
        assertFalse(policy.canWrite(null));
        assertDoesNotThrow(() -> policy.requireReadable(null, "missing"));
        ApiException denied = assertThrows(ApiException.class,
                () -> policy.requireWritable(null, "read only"));

        assertEquals(ErrorCode.FORBIDDEN, denied.getCode());
    }

    @Test
    void inaccessibleDocumentUsesNotFoundForReadAndForbiddenForWrite() {
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
    void delegatedOwnerIsBothReadableAndWritable() {
        UUID delegatedOwner = UUID.randomUUID();
        scope(false, Set.of(delegatedOwner));

        assertTrue(policy.canRead(delegatedOwner));
        assertTrue(policy.canWrite(delegatedOwner));
        assertDoesNotThrow(() -> policy.requireWritable(delegatedOwner, "denied"));
    }

    @Test
    void operationSpecificAuthorityCanBypassOwnerWithoutChangingGlobalScope() {
        UUID employeeId = UUID.randomUUID();
        AuthUser finance = new AuthUser(
                UUID.randomUUID(),
                employeeId,
                "finance",
                Set.of(),
                Set.of("finance_shipment_audit"),
                false,
                true,
                false);
        when(currentUser.get()).thenReturn(Optional.of(finance));
        scope(false, Set.of(employeeId));

        UUID otherOwner = UUID.randomUUID();
        assertFalse(policy.canRead(otherOwner));
        assertTrue(policy.canRead(otherOwner, "finance_shipment_audit"));
        assertTrue(policy.canWrite(otherOwner, "finance_shipment_audit"));
        assertDoesNotThrow(() -> policy.requireWritable(
                otherOwner, "denied", "finance_shipment_audit"));
    }

    @Test
    void nativeScopeUsesPublicOrDelegatedOwnersAndBindsCollection() {
        UUID owner = UUID.randomUUID();
        scope(false, Set.of(owner));

        SalesDocumentAccessPolicy.NativeReadScope nativeScope =
                policy.nativeReadScope("o.owner_employee_id", "salesOwners");
        Query query = mock(Query.class);

        nativeScope.bind(query);

        assertEquals(
                "(o.owner_employee_id IS NULL OR o.owner_employee_id IN (:salesOwners))",
                nativeScope.predicate());
        verify(query).setParameter("salesOwners", Set.of(owner));
    }

    @Test
    void materializedScopeTreatsNilOwnerAsLegacyPublicAndBindsDelegatedOwners() {
        UUID owner = UUID.randomUUID();
        UUID nil = new UUID(0L, 0L);
        OwnerVisibility.OwnerScope scope =
                new OwnerVisibility.OwnerScope(false, Set.of(owner));

        SalesDocumentAccessPolicy.NativeReadScope nativeScope =
                policy.nativeReadScopeWithLegacySentinel(
                        "owner_employee_id", "salesOwners", nil, scope);
        Query query = mock(Query.class);

        nativeScope.bind(query);

        assertEquals(
                "(owner_employee_id = '00000000-0000-0000-0000-000000000000'::uuid "
                        + "OR owner_employee_id IN (:salesOwners))",
                nativeScope.predicate());
        verify(query).setParameter("salesOwners", Set.of(owner));
    }

    @Test
    void newDocumentInheritsUpstreamOwnerOrFallsBackToCurrentEmployee() {
        UUID currentEmployee = UUID.randomUUID();
        UUID upstreamOwner = UUID.randomUUID();
        when(currentUser.requireEmployeeId()).thenReturn(currentEmployee);
        when(ownerVisibility.currentResponsible(SalesDocumentAccessPolicy.SCOPE, upstreamOwner))
                .thenReturn(upstreamOwner);
        when(ownerVisibility.currentResponsible(SalesDocumentAccessPolicy.SCOPE, currentEmployee))
                .thenReturn(currentEmployee);

        assertEquals(upstreamOwner, policy.ownerForNewDocument(upstreamOwner));
        assertEquals(currentEmployee, policy.ownerForNewDocument(null));
    }

    private void scope(boolean seeAll, Set<UUID> owners) {
        when(ownerVisibility.evaluate(
                SalesDocumentAccessPolicy.SCOPE,
                SalesDocumentAccessPolicy.VIEW_ALL))
                .thenReturn(new OwnerVisibility.OwnerScope(seeAll, owners));
    }
}
