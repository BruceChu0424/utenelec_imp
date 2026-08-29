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
    public static final String SUBCONTRACT_PERMISSION = "subcontract_receipt:price:view";
    public static final String FINANCE_PERMISSION = "finance:view:all";

    private final SecurityContextCurrentUser currentUser;

    public boolean canViewPurchase() {
        return hasPermission(PURCHASE_PERMISSION);
    }

    public boolean canViewSubcontract() {
        return hasPermission(SUBCONTRACT_PERMISSION);
    }

    public boolean canViewFinance() {
        return hasPermission(FINANCE_PERMISSION);
    }

    private boolean hasPermission(String permission) {
        return currentUser.get()
                .map(AuthUser::getPermissions)
                .map(permissions -> permissions.contains(permission))
                .orElse(false);
    }
}
