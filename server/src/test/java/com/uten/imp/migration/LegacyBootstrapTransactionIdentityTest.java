package com.uten.imp.migration;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class LegacyBootstrapTransactionIdentityTest {
    @Test void rowsOnEitherSideOfWrapKeepThePersistedNonzeroEpoch() {
        long epoch=1L<<32,claim=7*epoch+epoch-3,current=8*epoch+5;
        assertThat(LegacyBootstrapTransactionIdentity.full(epoch-1,claim,current)).isEqualTo(8*epoch-1);
        assertThat(LegacyBootstrapTransactionIdentity.full(3,claim,current)).isEqualTo(8*epoch+3);
    }
    @Test void anOlderRowOrTwoPossibleEpochsCannotBeGuessedIntoTheAllowedAttempt() {
        long epoch=1L<<32;
        assertThatThrownBy(()->LegacyBootstrapTransactionIdentity.full(2,7*epoch+10,7*epoch+100))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(()->LegacyBootstrapTransactionIdentity.full(20,7*epoch+10,8*epoch+30))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
