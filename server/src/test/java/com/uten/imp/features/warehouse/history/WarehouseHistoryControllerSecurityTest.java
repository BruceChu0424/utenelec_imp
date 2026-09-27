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
        assertFacetsEndpoint("purchaseReceiptFacets", "/purchase-receipts/facets",
                WarehouseHistoryPermissions.PURCHASE_RECEIPT_VIEW);
        assertEndpoint("purchaseReceipt", "/purchase-receipts/{id}",
                WarehouseHistoryPermissions.PURCHASE_RECEIPT_VIEW, false);
        assertEndpoint("subcontractReceipts", "/subcontract-receipts",
                WarehouseHistoryPermissions.SUBCONTRACT_RECEIPT_VIEW, true);
        assertFacetsEndpoint("subcontractReceiptFacets", "/subcontract-receipts/facets",
                WarehouseHistoryPermissions.SUBCONTRACT_RECEIPT_VIEW);
        assertEndpoint("subcontractReceipt", "/subcontract-receipts/{id}",
                WarehouseHistoryPermissions.SUBCONTRACT_RECEIPT_VIEW, false);
        assertEndpoint("subcontractMaterialIssues", "/subcontract-material-issues",
                WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_ISSUE_VIEW, true);
        assertFacetsEndpoint("subcontractMaterialIssueFacets", "/subcontract-material-issues/facets",
                WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_ISSUE_VIEW);
        assertEndpoint("subcontractMaterialIssue", "/subcontract-material-issues/{id}",
                WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_ISSUE_VIEW, false);
        assertEndpoint("subcontractReturns", "/subcontract-returns",
                WarehouseHistoryPermissions.SUBCONTRACT_RETURN_VIEW, true);
        assertFacetsEndpoint("subcontractReturnFacets", "/subcontract-returns/facets",
                WarehouseHistoryPermissions.SUBCONTRACT_RETURN_VIEW);
        assertEndpoint("subcontractReturn", "/subcontract-returns/{id}",
                WarehouseHistoryPermissions.SUBCONTRACT_RETURN_VIEW, false);
        assertEndpoint("subcontractMaterialReturns", "/subcontract-material-returns",
                WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_RETURN_VIEW, true);
        assertFacetsEndpoint("subcontractMaterialReturnFacets", "/subcontract-material-returns/facets",
                WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_RETURN_VIEW);
        assertEndpoint("subcontractMaterialReturn", "/subcontract-material-returns/{id}",
                WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_RETURN_VIEW, false);
        assertEndpoint("subcontractWastes", "/subcontract-wastes",
                WarehouseHistoryPermissions.SUBCONTRACT_WASTE_VIEW, true);
        assertFacetsEndpoint("subcontractWasteFacets", "/subcontract-wastes/facets",
                WarehouseHistoryPermissions.SUBCONTRACT_WASTE_VIEW);
        assertEndpoint("subcontractWaste", "/subcontract-wastes/{id}",
                WarehouseHistoryPermissions.SUBCONTRACT_WASTE_VIEW, false);
    }

    private static void assertEndpoint(
            String methodName,
            String path,
            String permission,
            boolean list) throws Exception {
        // 2026-09-25 单号列统一：列表方法追加 sort/order/billNo/sourceDocNo 四个
        // @RequestParam(required=false) 参数（单号列排序 + 值筛选）。
        Class<?>[] parameters = list
                ? new Class<?>[]{String.class, Short.class, LocalDate.class, LocalDate.class,
                    int.class, int.class, String.class, String.class, String.class, String.class}
                : new Class<?>[]{java.util.UUID.class};
        Method method = WarehouseHistoryController.class.getDeclaredMethod(methodName, parameters);
        GetMapping mapping = method.getAnnotation(GetMapping.class);
        PreAuthorize authorize = method.getAnnotation(PreAuthorize.class);
        assertThat(mapping.value()).containsExactly(path);
        assertThat(authorize.value()).isEqualTo("hasAuthority('" + permission + "')");
    }

    /** facets 端点（2026-09-25 单号列统一）：同分段查看权限，参数只有关键字/状态/日期。 */
    private static void assertFacetsEndpoint(
            String methodName,
            String path,
            String permission) throws Exception {
        Class<?>[] parameters = new Class<?>[]{String.class, Short.class, LocalDate.class, LocalDate.class};
        Method method = WarehouseHistoryController.class.getDeclaredMethod(methodName, parameters);
        GetMapping mapping = method.getAnnotation(GetMapping.class);
        PreAuthorize authorize = method.getAnnotation(PreAuthorize.class);
        assertThat(mapping.value()).containsExactly(path);
        assertThat(authorize.value()).isEqualTo("hasAuthority('" + permission + "')");
    }
}
