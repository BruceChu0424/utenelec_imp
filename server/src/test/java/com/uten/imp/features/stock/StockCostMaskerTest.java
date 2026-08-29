package com.uten.imp.features.stock;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class StockCostMaskerTest {

    @Test
    void missingCurrentUserFailsClosed() {
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.empty());

        assertFalse(new StockCostMasker(currentUser).canView());
    }

    @Test
    void onlyGoodsCostPermissionRevealsStockCosts() {
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.of(user(Set.of("stock:view"))));
        StockCostMasker masker = new StockCostMasker(currentUser);
        assertFalse(masker.canView());

        when(currentUser.get()).thenReturn(Optional.of(user(Set.of(
                "stock:view", StockCostMasker.PERMISSION))));
        assertTrue(masker.canView());
    }

    private static AuthUser user(Set<String> permissions) {
        return new AuthUser(
                UUID.randomUUID(), UUID.randomUUID(), "tester",
                Set.of(), permissions, false, true, false);
    }
}
