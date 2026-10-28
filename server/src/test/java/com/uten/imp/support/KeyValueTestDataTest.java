package com.uten.imp.support;

import java.math.BigDecimal;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatIllegalArgumentException;

class KeyValueTestDataTest {
    @Test void rejectsIncompletePairsRatherThanReadingPastTheEndOrDroppingTheLastKey() {
        assertThatIllegalArgumentException().isThrownBy(() -> KeyValueTestData.map("orphan"));
        assertThatIllegalArgumentException().isThrownBy(() -> KeyValueTestData.map("valid", 1, "orphan"));
    }

    @Test void preservesNullExactValuesInsertionOrderAndLastValueForARepeatedKey() {
        BigDecimal exact = new BigDecimal("9007199254740993.0001");
        var values = KeyValueTestData.map("amount", exact, "unknown", null, "status", "old", "status", "new");
        assertThat(values.keySet()).containsExactly("amount", "unknown", "status");
        assertThat(values.get("amount")).isSameAs(exact);
        assertThat(values).containsEntry("unknown", null).containsEntry("status", "new");
        values.put("derived", 2);
        assertThat(values).containsEntry("derived", 2);
    }

    @Test void allowsEmptyFixtureRows() {
        assertThat(KeyValueTestData.map()).isEmpty();
    }
}
