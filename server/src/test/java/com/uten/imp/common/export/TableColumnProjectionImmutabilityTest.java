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

    @Test void canonicalConstructorKeepsTheJsonContractAndNestedValidation() throws Exception {
        var mapper = new com.fasterxml.jackson.databind.ObjectMapper();
        var valid = mapper.readValue("""
                {"tableKey":"report","scope":"view_sales","columns":[{"key":"amount","label":"金额","width":120,"type":"money"}]}
                """, TableColumnProjection.class);
        var wire = mapper.writeValueAsBytes(valid);
        var roundTrip = mapper.readValue(wire, TableColumnProjection.class);
        // An absent JsonNode becomes an explicit NullNode on JSON round-trip;
        // the public contract is the JSON value, not that Java representation.
        assertEquals(mapper.readTree(wire), mapper.valueToTree(roundTrip));
        try (var factory = jakarta.validation.Validation.buildDefaultValidatorFactory()) {
            var validator = factory.getValidator();
            assertTrue(validator.validate(valid).isEmpty());
            var invalid = mapper.readValue("""
                    {"tableKey":"report","scope":"INVALID","columns":[{"key":"","width":0}]}
                    """, TableColumnProjection.class);
            var paths = validator.validate(invalid).stream().map(error -> error.getPropertyPath().toString())
                    .collect(java.util.stream.Collectors.toSet());
            assertEquals(java.util.Set.of("scope", "columns[0].key", "columns[0].width"), paths);
            var constructor = TableColumnProjection.class.getDeclaredConstructor(String.class, String.class, List.class);
            assertTrue(validator.forExecutables().validateConstructorParameters(constructor,
                    new Object[]{"report", "view_sales", valid.columns()}).isEmpty());
            assertFalse(validator.forExecutables().validateConstructorParameters(constructor,
                    new Object[]{"report", "view_sales", null}).isEmpty());
        }
    }
}
