package com.uten.imp.security;

import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import org.junit.jupiter.api.Test;

import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;

class DocumentAccessReadWriteSeparationTest {

    private final SalesDocumentAccessPolicy policy = new SalesDocumentAccessPolicy(
            mock(OwnerVisibility.class),
            mock(SecurityContextCurrentUser.class));

    @Test
    void manualVisibilityDoesNotGrantWriteResponsibility() {
        UUID owner = UUID.randomUUID();
        OwnerVisibility.OwnerScope readOnly = new OwnerVisibility.OwnerScope(
                false,
                Set.of(owner),
                Set.of());

        assertTrue(policy.canRead(owner, readOnly));
        assertFalse(policy.canWrite(owner, readOnly));
    }

    @Test
    void auditedHandoverOwnerIsReadableAndWritable() {
        UUID owner = UUID.randomUUID();
        OwnerVisibility.OwnerScope handedOver = new OwnerVisibility.OwnerScope(
                false,
                Set.of(owner),
                Set.of(owner));

        assertTrue(policy.canRead(owner, handedOver));
        assertTrue(policy.canWrite(owner, handedOver));
    }

    @Test
    void legacyOwnerlessDocumentRemainsReadOnlyEvenForWriteAllScope() {
        OwnerVisibility.OwnerScope writeAll = new OwnerVisibility.OwnerScope(
                true,
                Set.of(),
                Set.of());

        assertTrue(policy.canRead(null, writeAll));
        assertFalse(policy.canWrite(null, writeAll));
    }
}
