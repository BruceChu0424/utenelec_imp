package com.uten.imp.common.util;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;

class PostgresUuidOrderTest {
    @Test void unsignedOrderCoversBothSignedBoundariesWithoutStringConversion() {
        UUID highBefore = UUID.fromString("7fffffff-ffff-ffff-ffff-ffffffffffff");
        UUID highAfter = UUID.fromString("80000000-0000-0000-0000-000000000000");
        UUID lowBefore = UUID.fromString("00000000-0000-0000-7fff-ffffffffffff");
        UUID lowAfter = UUID.fromString("00000000-0000-0000-8000-000000000000");
        assertThat(highBefore.compareTo(highAfter)).isPositive();
        assertThat(lowBefore.compareTo(lowAfter)).isPositive();
        assertThat(List.of(highAfter, lowAfter, highBefore, lowBefore).stream()
                .sorted(PostgresUuidOrder.INSTANCE).toList())
                .containsExactly(lowBefore, lowAfter, highBefore, highAfter);
        assertThat(PostgresUuidOrder.INSTANCE.compare(highBefore, highBefore)).isZero();
    }
}
