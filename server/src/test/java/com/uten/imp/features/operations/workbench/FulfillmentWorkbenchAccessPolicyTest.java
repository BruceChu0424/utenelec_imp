package com.uten.imp.features.operations.workbench;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class FulfillmentWorkbenchAccessPolicyTest {

    @Test
    void requestPermissionDoesNotLeakLaterPurchaseDocuments() {
        FulfillmentWorkbenchAccessPolicy policy = policyWith(
                "purchase_request:view");

        var request = policy.documentAccess("PURCHASE", "PURCHASE_REQUEST");
        var order = policy.documentAccess("PURCHASE", "PURCHASE_ORDER");

        assertTrue(request.canView());
        assertFalse(request.canEdit());
        assertFalse(order.canView());
        assertFalse(order.canEdit());
        assertFalse(policy.canCreatePurchaseOrder());
    }

    @Test
    void batchCreationRequiresRequestViewAndOrderEdit() {
        FulfillmentWorkbenchAccessPolicy policy = policyWith(
                "purchase_request:view", "purchase_order:edit");

        assertTrue(policy.documentAccess("PURCHASE", "PURCHASE_REQUEST").canView());
        assertTrue(policy.canCreatePurchaseOrder());
    }

    @Test
    void batchCreationAlsoRequiresVisibilityOfItsRequestSource() {
        FulfillmentWorkbenchAccessPolicy policy = policyWith(
                "purchase_receipt:view", "purchase_order:edit");

        assertFalse(policy.canCreatePurchaseOrder());
    }

    @Test
    void aliasesAreDepartmentScopedAndUnknownTypesFailClosed() {
        FulfillmentWorkbenchAccessPolicy policy = policyWith(
                "purchase_order:view", "subcontract_order:view");

        assertTrue(policy.documentAccess("PURCHASE", "ORDER").canView());
        assertTrue(policy.documentAccess("SUBCONTRACT", "ORDER").canView());
        assertFalse(policy.documentAccess("WAREHOUSE", "ORDER").canView());
        assertFalse(policy.documentAccess("PURCHASE", "SUBCONTRACT_ORDER").canView());
        assertFalse(policy.documentAccess("PURCHASE", "UNKNOWN").canView());
    }

    private static FulfillmentWorkbenchAccessPolicy policyWith(String... permissions) {
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        AuthUser user = new AuthUser(
                UUID.randomUUID(),
                UUID.randomUUID(),
                "tester",
                Set.of(),
                Set.of(permissions),
                false,
                true,
                false);
        when(currentUser.get()).thenReturn(Optional.of(user));
        return new FulfillmentWorkbenchAccessPolicy(currentUser);
    }
}
