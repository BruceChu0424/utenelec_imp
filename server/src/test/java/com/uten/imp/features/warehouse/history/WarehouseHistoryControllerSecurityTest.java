package com.uten.imp.features.warehouse.history;

import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;

import java.lang.reflect.Method;
import java.time.LocalDate;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class WarehouseHistoryControllerSecurityTest {

    @Test
    void controllerUsesDedicatedPrefixAndEveryEndpointHasItsExactAuthority() throws Exception {
        RequestMapping root = WarehouseHistoryController.class.getAnnotation(RequestMapping.class);
        assertThat(root.value()).containsExactly("/api/warehouse/document-history");

        assertEndpoint("purchaseReceipts", "/purchase-receipts",
                WarehouseHistoryPermissions.PURCHASE_RECEIPT_VIEW, true);
        assertEndpoint("purchaseReceipt", "/purchase-receipts/{id}",
                WarehouseHistoryPermissions.PURCHASE_RECEIPT_VIEW, false);
        assertEndpoint("subcontractReceipts", "/subcontract-receipts",
                WarehouseHistoryPermissions.SUBCONTRACT_RECEIPT_VIEW, true);
        assertEndpoint("subcontractReceipt", "/subcontract-receipts/{id}",
                WarehouseHistoryPermissions.SUBCONTRACT_RECEIPT_VIEW, false);
        assertEndpoint("subcontractMaterialIssues", "/subcontract-material-issues",
                WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_ISSUE_VIEW, true);
        assertEndpoint("subcontractMaterialIssue", "/subcontract-material-issues/{id}",
                WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_ISSUE_VIEW, false);
        assertEndpoint("subcontractReturns", "/subcontract-returns",
                WarehouseHistoryPermissions.SUBCONTRACT_RETURN_VIEW, true);
        assertEndpoint("subcontractReturn", "/subcontract-returns/{id}",
                WarehouseHistoryPermissions.SUBCONTRACT_RETURN_VIEW, false);
        assertEndpoint("subcontractMaterialReturns", "/subcontract-material-returns",
                WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_RETURN_VIEW, true);
        assertEndpoint("subcontractMaterialReturn", "/subcontract-material-returns/{id}",
                WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_RETURN_VIEW, false);
        assertEndpoint("subcontractWastes", "/subcontract-wastes",
                WarehouseHistoryPermissions.SUBCONTRACT_WASTE_VIEW, true);
        assertEndpoint("subcontractWaste", "/subcontract-wastes/{id}",
                WarehouseHistoryPermissions.SUBCONTRACT_WASTE_VIEW, false);
    }

    private static void assertEndpoint(
            String methodName,
            String path,
            String permission,
            boolean list) throws Exception {
        Class<?>[] parameters = list
                ? new Class<?>[]{String.class, Short.class, LocalDate.class, LocalDate.class, int.class, int.class}
                : new Class<?>[]{java.util.UUID.class};
        Method method = WarehouseHistoryController.class.getDeclaredMethod(methodName, parameters);
        GetMapping mapping = method.getAnnotation(GetMapping.class);
        PreAuthorize authorize = method.getAnnotation(PreAuthorize.class);
        assertThat(mapping.value()).containsExactly(path);
        assertThat(authorize.value()).isEqualTo("hasAuthority('" + permission + "')");
    }
}
