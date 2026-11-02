package com.uten.imp.security;

import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

/**
 * Cross-feature authority for commercial price visibility.
 *
 * <p>This security-layer component prevents purchase and subcontract features from depending on
 * one another merely to answer the same authorization question. Missing authentication is
 * deliberately fail-closed.
 */
@Component
@RequiredArgsConstructor
public class CommercialPriceVisibility {

    public static final String PURCHASE_PERMISSION = "purchase_receipt:price:view";
    public static final String PURCHASE_ORDER_PERMISSION =
            "purchase_order:price:view";
    public static final String PURCHASE_RETURN_PERMISSION =
            "purchase_return:price:view";
    public static final String PURCHASE_REPORT_PERMISSION =
            "purchase_report:price:view";
    public static final String SUBCONTRACT_INQUIRY_PERMISSION =
            "subcontract_inquiry:price:view";
    public static final String SUBCONTRACT_ORDER_PERMISSION =
            "subcontract_order:price:view";
    public static final String SUBCONTRACT_RECEIPT_PERMISSION =
            "subcontract_receipt:price:view";
    public static final String SUBCONTRACT_RETURN_PERMISSION =
            "subcontract_return:price:view";
    public static final String SUBCONTRACT_WASTE_SUGGESTION_PERMISSION =
            "subcontract_waste:suggestion:view";
    public static final String SUBCONTRACT_REPORT_PERMISSION =
            "subcontract_report:price:view";
    public static final String FINANCE_PERMISSION = "finance:view:all";

    private final SecurityContextCurrentUser currentUser;

    public boolean canViewPurchaseOrder() {
        return canViewCommercial(PURCHASE_ORDER_PERMISSION);
    }

    public boolean canViewPurchaseReceipt() {
        return canViewCommercial(PURCHASE_PERMISSION);
    }

    public boolean canViewPurchaseReturn() {
        return canViewCommercial(PURCHASE_RETURN_PERMISSION);
    }

    public boolean canViewPurchaseReport() {
        return canViewCommercial(PURCHASE_REPORT_PERMISSION);
    }

    public boolean canViewSubcontractInquiry() {
        return canViewCommercial(SUBCONTRACT_INQUIRY_PERMISSION);
    }

    public boolean canViewSubcontractOrder() {
        return canViewCommercial(SUBCONTRACT_ORDER_PERMISSION);
    }

    public boolean canViewSubcontractReceipt() {
        return canViewCommercial(SUBCONTRACT_RECEIPT_PERMISSION);
    }

    public boolean canViewSubcontractReturn() {
        return canViewCommercial(SUBCONTRACT_RETURN_PERMISSION);
    }

    public boolean canViewSubcontractWasteSuggestion() {
        return canViewCommercial(
                SUBCONTRACT_WASTE_SUGGESTION_PERMISSION);
    }

    public boolean canViewSubcontractReport() {
        return canViewCommercial(SUBCONTRACT_REPORT_PERMISSION);
    }

    /**
     * Historical material issue/return DTOs still carry cost-shaped columns,
     * while their current business pages expose no commercial price fact.
     * Finance-wide source scope and explicit goods cost visibility are both required.
     */
    public boolean canViewSubcontractMaterialCost() {
        return canViewFinance() && hasPermission("goods:cost:view");
    }

    public boolean canViewFinance() {
        return hasPermission(FINANCE_PERMISSION);
    }

    private boolean canViewCommercial(String pagePermission) {
        return currentUser.get().map(user -> canViewCommercial(user.getPermissions(),pagePermission)).orElse(false);
    }


    public static boolean canViewCommercial(java.util.Set<String> permissions,String pricePermission) {
        return pricePermission != null && permissions.contains(pricePermission);
    }

    private boolean hasPermission(String permission) {
        return currentUser.get()
                .map(AuthUser::getPermissions)
                .map(permissions -> permissions.contains(permission))
                .orElse(false);
    }
}
