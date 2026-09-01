package com.uten.imp.security;

import com.uten.imp.features.purchase.receipt.ReceiptPriceMasker;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Optional;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class CommercialPriceVisibilityTest {

    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private AuthUser authUser;
    @InjectMocks private CommercialPriceVisibility visibility;

    @Test
    void pagePermissionsRemainIndependentAndMissingAuthenticationFailsClosed() {
        when(currentUser.get()).thenReturn(Optional.of(authUser));
        when(authUser.getPermissions()).thenReturn(Set.of(
                CommercialPriceVisibility.PURCHASE_PERMISSION,
                CommercialPriceVisibility.SUBCONTRACT_RECEIPT_PERMISSION));

        assertTrue(visibility.canViewPurchaseReceipt());
        assertFalse(visibility.canViewPurchaseOrder());
        assertFalse(visibility.canViewPurchaseReturn());
        assertFalse(visibility.canViewPurchaseReport());
        assertTrue(visibility.canViewSubcontractReceipt());
        assertFalse(visibility.canViewSubcontractOrder());
        assertFalse(visibility.canViewSubcontractReturn());
        assertFalse(visibility.canViewSubcontractReport());
        assertFalse(visibility.canViewSubcontractMaterialCost());
        assertFalse(visibility.canViewFinance());

        when(authUser.getPermissions()).thenReturn(Set.of(
                CommercialPriceVisibility.PURCHASE_ORDER_PERMISSION));
        assertTrue(visibility.canViewPurchaseOrder());
        assertFalse(visibility.canViewPurchaseReceipt());
        assertFalse(visibility.canViewPurchaseReturn());
        assertFalse(visibility.canViewPurchaseReport());

        when(authUser.getPermissions()).thenReturn(Set.of(
                CommercialPriceVisibility.SUBCONTRACT_ORDER_PERMISSION));
        assertFalse(visibility.canViewPurchaseReceipt());
        assertFalse(visibility.canViewPurchaseOrder());
        assertTrue(visibility.canViewSubcontractOrder());
        assertFalse(visibility.canViewSubcontractReceipt());
        assertFalse(visibility.canViewSubcontractMaterialCost());

        when(authUser.getPermissions()).thenReturn(Set.of(
                CommercialPriceVisibility.FINANCE_PERMISSION));
        assertTrue(visibility.canViewSubcontractInquiry());
        assertTrue(visibility.canViewSubcontractOrder());
        assertTrue(visibility.canViewSubcontractReceipt());
        assertTrue(visibility.canViewSubcontractReturn());
        assertTrue(visibility.canViewSubcontractWasteSuggestion());
        assertTrue(visibility.canViewSubcontractReport());
        assertTrue(visibility.canViewSubcontractMaterialCost());
        assertTrue(visibility.canViewPurchaseOrder());
        assertTrue(visibility.canViewPurchaseReceipt());
        assertTrue(visibility.canViewPurchaseReturn());
        assertTrue(visibility.canViewPurchaseReport());

        when(currentUser.get()).thenReturn(Optional.empty());
        assertFalse(visibility.canViewPurchaseReceipt());
        assertFalse(visibility.canViewPurchaseOrder());
        assertFalse(visibility.canViewSubcontract());
        assertFalse(visibility.canViewSubcontractOrder());
        assertFalse(visibility.canViewSubcontractMaterialCost());
        assertFalse(visibility.canViewFinance());
    }

    @Test
    void legacyReceiptMaskerDelegatesToSharedSecurityPolicy() {
        CommercialPriceVisibility delegate = mock(CommercialPriceVisibility.class);
        when(delegate.canViewPurchaseReceipt()).thenReturn(true);
        when(delegate.canViewSubcontractReceipt()).thenReturn(false);
        ReceiptPriceMasker legacy = new ReceiptPriceMasker(delegate);

        assertTrue(legacy.canViewPurchaseReceipt());
        assertFalse(legacy.canViewSubcontractReceipt());
    }
}
