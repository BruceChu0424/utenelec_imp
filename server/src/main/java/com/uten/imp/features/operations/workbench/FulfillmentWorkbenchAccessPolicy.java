package com.uten.imp.features.operations.workbench;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.Map;

/**
 * Resolves the exact document permissions exposed by the fulfillment read side.
 *
 * <p>The workbench endpoint deliberately accepts any read permission belonging
 * to the selected department. That permission is only enough to see the common
 * fulfillment task. It must never imply access to every linked business
 * document. Unknown department/document combinations fail closed.</p>
 *
 * <p>The source view applies active-row scope. Warehouse production tasks add
 * the current {@code SUB_WH} organization-tree object scope before any rows or
 * counts are returned; document metadata still requires its exact view
 * permission. Purchase/subcontract retain their module policies.</p>
 */
@Component
@RequiredArgsConstructor
public class FulfillmentWorkbenchAccessPolicy {

    private static final Map<String, PermissionPair> WAREHOUSE = Map.of(
            "DRAW", pair("stock_doc:view", "stock_doc:edit"));

    private static final Map<String, PermissionPair> PURCHASE = Map.ofEntries(
            Map.entry("PURCHASE_REQUEST", pair("purchase_request:view", "purchase_order:decompose")),
            Map.entry("REQUEST", pair("purchase_request:view", "purchase_order:decompose")),
            Map.entry("PURCHASE_ORDER", pair("purchase_order:view", "purchase_order:edit")),
            Map.entry("ORDER", pair("purchase_order:view", "purchase_order:edit")),
            Map.entry("PURCHASE_RECEIPT", pair("purchase_receipt:view", "purchase_receipt:edit")),
            Map.entry("RECEIPT", pair("purchase_receipt:view", "purchase_receipt:edit")),
            Map.entry("PURCHASE_RETURN", pair("purchase_return:view", "purchase_return:edit")),
            Map.entry("RETURN", pair("purchase_return:view", "purchase_return:edit")));

    private static final Map<String, PermissionPair> SUBCONTRACT = Map.ofEntries(
            Map.entry("SUBCONTRACT_INQUIRY", pair("subcontract_inquiry:view", "subcontract_inquiry:edit")),
            Map.entry("INQUIRY", pair("subcontract_inquiry:view", "subcontract_inquiry:edit")),
            Map.entry("SUBCONTRACT_APPLICATION", pair("subcontract_application:view", "subcontract_order:decompose")),
            Map.entry("APPLICATION", pair("subcontract_application:view", "subcontract_order:decompose")),
            Map.entry("SUBCONTRACT_ORDER", pair("subcontract_order:view", "subcontract_order:edit")),
            Map.entry("ORDER", pair("subcontract_order:view", "subcontract_order:edit")),
            Map.entry("SUBCONTRACT_RECEIPT", pair("subcontract_receipt:view", "subcontract_receipt:edit")),
            Map.entry("RECEIPT", pair("subcontract_receipt:view", "subcontract_receipt:edit")),
            Map.entry("SUBCONTRACT_MATERIAL_ISSUE", pair("subcontract_material_issue:view", "subcontract_material_issue:edit")),
            Map.entry("MATERIAL_ISSUE", pair("subcontract_material_issue:view", "subcontract_material_issue:edit")),
            Map.entry("SUBCONTRACT_RETURN", pair("subcontract_return:view", "subcontract_return:edit")),
            Map.entry("RETURN", pair("subcontract_return:view", "subcontract_return:edit")),
            Map.entry("SUBCONTRACT_MATERIAL_RETURN", pair("subcontract_material_return:view", "subcontract_material_return:edit")),
            Map.entry("MATERIAL_RETURN", pair("subcontract_material_return:view", "subcontract_material_return:edit")),
            Map.entry("SUBCONTRACT_WASTE", pair("subcontract_waste:view", "subcontract_waste:edit")),
            Map.entry("WASTE", pair("subcontract_waste:view", "subcontract_waste:edit")));

    private final SecurityContextCurrentUser currentUser;
    private final ProductionStockTaskAccessPolicy productionStockTaskAccess;

    public boolean canAccessWarehouseTasks() {
        return productionStockTaskAccess.canAccessWarehouseTasks();
    }

    public DocumentAccess documentAccess(String department, String rawDocumentType) {
        if (department == null || rawDocumentType == null) return DocumentAccess.denied();
        PermissionPair permissions = switch (department.strip().toUpperCase()) {
            case "WAREHOUSE" -> WAREHOUSE.get(rawDocumentType.strip().toUpperCase());
            case "PURCHASE" -> PURCHASE.get(rawDocumentType.strip().toUpperCase());
            case "SUBCONTRACT" -> SUBCONTRACT.get(rawDocumentType.strip().toUpperCase());
            default -> null;
        };
        if (permissions == null) return DocumentAccess.denied();
        boolean canView = hasAuthority(permissions.view());
        return new DocumentAccess(canView, canView && hasAuthority(permissions.edit()));
    }

    public boolean canCreatePurchaseOrder() {
        // This capability is specifically for carrying selected request lines
        // into a new order, so both the source read and target write gates apply.
        return hasAuthority("purchase_request:view")
                && hasAuthority("purchase_order:create")
                && hasAuthority("purchase_order:decompose");
    }

    public boolean canCreateSubcontractOrder() {
        return hasAuthority("subcontract_application:view")
                && hasAuthority("subcontract_order:create")
                && hasAuthority("subcontract_order:decompose");
    }

    private boolean hasAuthority(String authority) {
        AuthUser user = currentUser.get().orElse(null);
        return user != null && (user.isSuperAdmin() || user.getAuthorities().stream()
                .anyMatch(granted -> authority.equals(granted.getAuthority())));
    }

    private static PermissionPair pair(String view, String edit) {
        return new PermissionPair(view, edit);
    }

    private record PermissionPair(String view, String edit) {}

    public record DocumentAccess(boolean canView, boolean canEdit) {
        private static DocumentAccess denied() {
            return new DocumentAccess(false, false);
        }
    }
}
