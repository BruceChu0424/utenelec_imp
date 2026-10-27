package com.uten.imp.common.export;

import org.junit.jupiter.api.Test;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class TableColumnProjectionImmutabilityTest {
    @Test void authorizationSelectionCannotBeChangedThroughTheOriginalOrReturnedList() {
        var original = new TableColumnProjection.Column("amount", "原始金额", 120d, "money", null);
        var requested = new ArrayList<>(List.of(original));
        var projection = new TableColumnProjection("report", "view_sales", requested);
        requested.clear();
        requested.add(new TableColumnProjection.Column("private-field", "其他字段", 120d, "text", null));
        assertEquals(List.of(original), projection.columns());
        assertThrows(UnsupportedOperationException.class, () -> projection.columns().clear());
    }

    @Test void malformedInputRemainsAvailableForTheExistingStructuredValidator() {
        assertNull(new TableColumnProjection("report", "view_sales", null).columns());
        var projection = new TableColumnProjection("report", "view_sales", new ArrayList<>(Arrays.asList((TableColumnProjection.Column) null)));
        assertEquals(1, projection.columns().size());
        assertNull(projection.columns().getFirst());
    }
}
