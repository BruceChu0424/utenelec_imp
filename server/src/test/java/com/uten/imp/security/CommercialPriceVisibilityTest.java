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
    void permissionsRemainIndependentAndMissingAuthenticationFailsClosed() {
        when(currentUser.get()).thenReturn(Optional.of(authUser));
        when(authUser.getPermissions()).thenReturn(Set.of(
                CommercialPriceVisibility.PURCHASE_PERMISSION,
                CommercialPriceVisibility.FINANCE_PERMISSION));

        assertTrue(visibility.canViewPurchase());
        assertFalse(visibility.canViewSubcontract());
        assertTrue(visibility.canViewFinance());

        when(currentUser.get()).thenReturn(Optional.empty());
        assertFalse(visibility.canViewPurchase());
        assertFalse(visibility.canViewSubcontract());
        assertFalse(visibility.canViewFinance());
    }

    @Test
    void legacyReceiptMaskerDelegatesToSharedSecurityPolicy() {
        CommercialPriceVisibility delegate = mock(CommercialPriceVisibility.class);
        when(delegate.canViewPurchase()).thenReturn(true);
        when(delegate.canViewSubcontract()).thenReturn(false);
        ReceiptPriceMasker legacy = new ReceiptPriceMasker(delegate);

        assertTrue(legacy.canViewPurchase());
        assertFalse(legacy.canViewSubcontract());
    }
}
