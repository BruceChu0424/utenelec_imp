package com.uten.imp.features.operations.workbench;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class FulfillmentWorkbenchAccessPolicyTest {

    @Test void definingUnknownMaterialsRequiresStockViewAndIssueRatherThanOrdinaryEdit() {
        var readOnly = policyWith("stock_doc:view", "stock_doc:edit")
                .documentAccess("WAREHOUSE", "MATERIAL_DISCOVERY");
        assertTrue(readOnly.canView());
        assertFalse(readOnly.canEdit());
        assertTrue(policyWith("stock_doc:view", "stock_doc:issue")
                .documentAccess("WAREHOUSE", "MATERIAL_DISCOVERY").canEdit());
        assertFalse(policyWith("stock_doc:issue")
                .documentAccess("WAREHOUSE", "MATERIAL_DISCOVERY").canView());
        assertFalse(policyWith("stock_doc:view", "stock_doc:issue")
                .documentAccess("PURCHASE", "MATERIAL_DISCOVERY").canView());
    }

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
    void batchCreationRequiresRequestViewCreateAndDecompose() {
        FulfillmentWorkbenchAccessPolicy policy = policyWith(
                "purchase_request:view", "purchase_order:create",
                "purchase_order:decompose");

        assertTrue(policy.documentAccess("PURCHASE", "PURCHASE_REQUEST").canView());
        assertTrue(policy.canCreatePurchaseOrder());
    }

    @Test
    void batchCreationAlsoRequiresVisibilityOfItsRequestSource() {
        FulfillmentWorkbenchAccessPolicy policy = policyWith(
                "purchase_receipt:view", "purchase_order:create", "purchase_order:decompose");

        assertFalse(policy.canCreatePurchaseOrder());
    }

    @Test
    void subcontractOrderCreationRequiresDemandViewCreateAndDecompose() {
        FulfillmentWorkbenchAccessPolicy allowed = policyWith(
                "subcontract_application:view", "subcontract_order:create",
                "subcontract_order:decompose");
        FulfillmentWorkbenchAccessPolicy denied = policyWith(
                "subcontract_application:view", "subcontract_order:create");
        FulfillmentWorkbenchAccessPolicy noSource = policyWith("subcontract_order:create", "subcontract_order:decompose");

        assertTrue(allowed.canCreateSubcontractOrder());
        assertFalse(denied.canCreateSubcontractOrder());
        assertFalse(noSource.canCreateSubcontractOrder());
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

    @Test
    void shortDeliveryRequiresTheExactViewAndDecisionPermissions() {
        assertFalse(policyWith("subcontract_order:view").canDecideSubcontractShortDelivery());
        assertFalse(policyWith("subcontract_short_delivery:decide").canDecideSubcontractShortDelivery());
        assertTrue(policyWith("subcontract_order:view", "subcontract_short_delivery:decide")
                .canDecideSubcontractShortDelivery());
    }

    @Test
    void warehouseTasksRequireTheActualBatchIssuePermissionsAndPhysicalResponsibility() {
        var current = mock(SecurityContextCurrentUser.class);
        var warehouse = mock(ProductionStockTaskAccessPolicy.class);
        when(warehouse.canAccessWarehouseTasks()).thenReturn(true);
        var policy = new FulfillmentWorkbenchAccessPolicy(current, warehouse, mock(OwnerVisibility.class));
        for (Set<String> permissions : java.util.List.of(Set.of("stock_doc:view"),
                Set.of("stock_doc:view", "stock_doc:issue"), Set.of("stock_doc:view", "stock_doc:approve"))) {
            when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(),
                    "warehouse", permissions, false, true, false)));
            assertFalse(policy.canHandleWarehouseTasks());
        }
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(),
                "warehouse", Set.of("stock_doc:view", "stock_doc:approve", "stock_doc:issue"), false, true, false)));
        assertTrue(policy.canHandleWarehouseTasks());
        when(warehouse.canAccessWarehouseTasks()).thenReturn(false);
        assertFalse(policy.canHandleWarehouseTasks());
    }

    @Test
    void taskScopeUsesTheModuleOwnerPolicyWithoutAnActionBypass() {
        var owners = mock(OwnerVisibility.class);
        UUID owner = UUID.randomUUID();
        UUID readOnlyOwner = UUID.randomUUID();
        when(owners.evaluate("subcontract", "subcontract:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(owner, readOnlyOwner), Set.of(owner)));
        var policy = new FulfillmentWorkbenchAccessPolicy(mock(SecurityContextCurrentUser.class),
                mock(ProductionStockTaskAccessPolicy.class), owners);
        var scope = policy.orderTaskScope("SUBCONTRACT", "task_order.maker_id", "owners");
        org.junit.jupiter.api.Assertions.assertEquals("task_order.maker_id IN (:owners)", scope.predicate());
        org.junit.jupiter.api.Assertions.assertEquals(Set.of(owner), scope.owners());
    }

    private static FulfillmentWorkbenchAccessPolicy policyWith(String... permissions) {
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        AuthUser user = new AuthUser(
                UUID.randomUUID(),
                UUID.randomUUID(),
                "tester",
                Set.of(permissions),
                false,
                true,
                false);
        when(currentUser.get()).thenReturn(Optional.of(user));
        return new FulfillmentWorkbenchAccessPolicy(
                currentUser, mock(ProductionStockTaskAccessPolicy.class), mock(OwnerVisibility.class));
    }
}
