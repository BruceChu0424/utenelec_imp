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
    void ownerlessDocumentIsNeitherReadableNorWritableWithoutCompanyWideScope() {
        // ADR-109 / security-18：没有负责人不再等于公共可读。
        scope(false, Set.of());

        assertFalse(policy.canRead(null));
        assertFalse(policy.canWrite(null));
        assertEquals(ErrorCode.NOT_FOUND, assertThrows(ApiException.class,
                () -> policy.requireReadable(null, "missing")).getCode());
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
                Set.of("sales_shipment_finance:view"),
                false,
                true,
                false);
        when(currentUser.get()).thenReturn(Optional.of(finance));
        scope(false, Set.of(employeeId));

        UUID otherOwner = UUID.randomUUID();
        assertFalse(policy.canRead(otherOwner));
        assertTrue(policy.canRead(otherOwner, "sales_shipment_finance:view"));
        assertTrue(policy.canWrite(otherOwner, "sales_shipment_finance:view"));
        assertDoesNotThrow(() -> policy.requireWritable(
                otherOwner, "denied", "sales_shipment_finance:view"));
    }

    @Test
    void nativeScopeBindsOnlyVisibleOwnersAndNeverTreatsMissingOwnerAsPublic() {
        UUID owner = UUID.randomUUID();
        scope(false, Set.of(owner));

        SalesDocumentAccessPolicy.NativeReadScope nativeScope =
                policy.nativeReadScope("o.owner_employee_id", "salesOwners");
        Query query = mock(Query.class);

        nativeScope.bind(query);

        // permissions-10：空归属不再是「全员可读」旁路。
        assertEquals("o.owner_employee_id IN (:salesOwners)", nativeScope.predicate());
        verify(query).setParameter("salesOwners", Set.of(owner));
    }

    @Test
    void documentWithoutOwnerIsReadableOnlyByCompanyWideScope() {
        scope(false, Set.of(UUID.randomUUID()));
        assertFalse(policy.canRead(null));
        assertFalse(policy.canWrite(null));

        scope(true, Set.of());
        assertTrue(policy.canRead(null));
        assertFalse(policy.canWrite(null), "无归属单据即使全量高权也须先补负责人再写");
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
