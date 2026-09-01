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

    /** Receipt-only compatibility alias. */
    @Deprecated(forRemoval = false)
    public boolean canViewPurchase() {
        return canViewPurchaseReceipt();
    }

    public boolean canViewPurchaseOrder() {
        return canViewPurchaseCommercial(PURCHASE_ORDER_PERMISSION);
    }

    public boolean canViewPurchaseReceipt() {
        return canViewPurchaseCommercial(PURCHASE_PERMISSION);
    }

    public boolean canViewPurchaseReturn() {
        return canViewPurchaseCommercial(PURCHASE_RETURN_PERMISSION);
    }

    public boolean canViewPurchaseReport() {
        return canViewPurchaseCommercial(PURCHASE_REPORT_PERMISSION);
    }

    /** Compatibility alias for the receipt arrival path only. */
    @Deprecated(forRemoval = false)
    public boolean canViewSubcontract() {
        return canViewSubcontractReceipt();
    }

    public boolean canViewSubcontractInquiry() {
        return canViewSubcontractCommercial(SUBCONTRACT_INQUIRY_PERMISSION);
    }

    public boolean canViewSubcontractOrder() {
        return canViewSubcontractCommercial(SUBCONTRACT_ORDER_PERMISSION);
    }

    public boolean canViewSubcontractReceipt() {
        return canViewSubcontractCommercial(SUBCONTRACT_RECEIPT_PERMISSION);
    }

    public boolean canViewSubcontractReturn() {
        return canViewSubcontractCommercial(SUBCONTRACT_RETURN_PERMISSION);
    }

    public boolean canViewSubcontractWasteSuggestion() {
        return canViewSubcontractCommercial(
                SUBCONTRACT_WASTE_SUGGESTION_PERMISSION);
    }

    public boolean canViewSubcontractReport() {
        return canViewSubcontractCommercial(SUBCONTRACT_REPORT_PERMISSION);
    }

    /**
     * Historical material issue/return DTOs still carry cost-shaped columns,
     * while their current business pages expose no commercial price fact.
     * Only finance-wide authority may unmask those compatibility fields.
     */
    public boolean canViewSubcontractMaterialCost() {
        return canViewFinance();
    }

    public boolean canViewFinance() {
        return hasPermission(FINANCE_PERMISSION);
    }

    private boolean canViewSubcontractCommercial(String pagePermission) {
        return hasPermission(pagePermission) || canViewFinance();
    }

    private boolean canViewPurchaseCommercial(String pagePermission) {
        return hasPermission(pagePermission) || canViewFinance();
    }

    private boolean hasPermission(String permission) {
        return currentUser.get()
                .map(AuthUser::getPermissions)
                .map(permissions -> permissions.contains(permission))
                .orElse(false);
    }
}
