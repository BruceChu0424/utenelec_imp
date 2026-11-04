package com.uten.imp.features.master.reference;

import org.junit.jupiter.api.Test;
import java.util.Set;
import static org.junit.jupiter.api.Assertions.*;

class BusinessMasterReferenceAccessTest {
    @Test void supplierApplicationsSelectOnlyTheirRequiredReadOnlySupplierReferences(){
        for(String permission:Set.of("application:apply:prepayment","application:apply:supplier_payment","application:apply")){
            assertTrue(BusinessMasterReferenceAccess.allowed("supplier",Set.of(permission)));
            for(String resource:Set.of("client","goods","account"))assertFalse(BusinessMasterReferenceAccess.allowed(resource,Set.of(permission)),resource);
        }
        assertFalse(BusinessMasterReferenceAccess.allowed("supplier",Set.of("application:apply:travel")));
    }
    @Test void aReceiptOperationIncludesItsReadOnlyChoicesButNotFinanceAccounts() {
        var permissions = Set.of("warehouse_inbound:view", "warehouse_inbound:stock_in");
        for (String resource : Set.of("supplier", "goods", "warehouse", "unit", "department")) {
            assertTrue(BusinessMasterReferenceAccess.allowed(resource, permissions), resource);
        }
        assertFalse(BusinessMasterReferenceAccess.allowed("account", permissions));
        assertFalse(BusinessMasterReferenceAccess.allowed("client", permissions));
    }

    @Test void existingOperationsSelectTheirOwnReferencesWithoutInventingMasterPermissions() {
        assertTrue(BusinessMasterReferenceAccess.allowed("supplier", Set.of("purchase_order:create")));
        assertFalse(BusinessMasterReferenceAccess.allowed("client", Set.of("purchase_order:create")));
        assertTrue(BusinessMasterReferenceAccess.allowed("client", Set.of("sales_order:create")));
        assertFalse(BusinessMasterReferenceAccess.allowed("supplier", Set.of("sales_order:create")));
        assertTrue(BusinessMasterReferenceAccess.allowed("account", Set.of("finance_payment:create")));
        assertTrue(BusinessMasterReferenceAccess.allowed("account", Set.of("subcontract_loss_claim:fulfill")));
        assertTrue(BusinessMasterReferenceAccess.allowed("account", Set.of("subcontract_loss_claim:view")));
        assertFalse(BusinessMasterReferenceAccess.allowed("account", Set.of("expense:apply")));
        assertTrue(BusinessMasterReferenceAccess.allowed("department", Set.of("employee:view")),
                "Existing HR department metadata access is not a finance or goods grant");
        for (String resource : Set.of("supplier", "client", "goods", "account")) {
            assertFalse(BusinessMasterReferenceAccess.allowed(resource, Set.of("employee:view")), resource);
            assertFalse(BusinessMasterReferenceAccess.allowed(resource, Set.of("unrelated:create")), resource);
        }
        assertFalse(BusinessMasterReferenceAccess.allowed("unregistered-resource", Set.of("goods:view")));
    }
}
